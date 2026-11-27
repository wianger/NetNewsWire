//
//  WICImaging.swift
//  RSCore
//
//  Image decoding, scaling, and PNG encoding on Windows through the Windows Imaging Component —
//  the codec layer under Direct2D, WinUI's BitmapDecoder, and the Windows shell. It reads
//  PNG, JPEG, GIF, BMP, ICO, and TIFF out of the box, plus WebP, HEIF, and AVIF where
//  Windows has the codec. This is the Windows counterpart to ImageIO.
//

#if os(Windows)

import Foundation
import WinSDK

/// Decoded pixels in 32-bit premultiplied BGRA, the format Direct2D and WinUI's
/// SoftwareBitmap draw without converting. Rows are packed: `bytesPerRow` is `width * 4`.
public struct RSBitmap: Sendable, Equatable {

	public let width: Int
	public let height: Int
	public let pixels: [UInt8]

	public var bytesPerRow: Int {
		width * RSBitmap.bytesPerPixel
	}

	public static let bytesPerPixel = 4

	public init?(width: Int, height: Int, pixels: [UInt8]) {
		guard width > 0, height > 0, pixels.count == width * height * RSBitmap.bytesPerPixel else {
			return nil
		}
		self.width = width
		self.height = height
		self.pixels = pixels
	}
}

public enum WICImaging {

	/// Index and pixel dimensions of one frame, as stored (before EXIF orientation).
	public struct FrameInfo: Sendable {
		public let index: Int
		public let width: Int
		public let height: Int
	}

	/// The frame with the longest side, read from the image header without decoding pixels.
	public static func largestFrame(_ data: Data) -> FrameInfo? {
		withDecoder(data) { _, decoder in
			largestFrame(decoder)
		}
	}

	/// How many frames the image has — several for ICO, animated GIF, and multi-page TIFF.
	public static func frameCount(_ data: Data) -> Int? {
		withDecoder(data) { _, decoder in
			var frameCount: UINT = 0
			guard succeeded(decoder.vtable.GetFrameCount(decoder.pointer, &frameCount)) else {
				return nil
			}
			return Int(frameCount)
		}
	}

	/// True when the frame's EXIF orientation swaps width and height.
	public static func isRotatedQuarterTurn(_ data: Data, frameIndex: Int) -> Bool {
		withDecoder(data) { _, decoder in
			guard let frame = frame(decoder, index: frameIndex) else {
				return false
			}
			return orientation(of: frame).swapsWidthAndHeight
		} ?? false
	}

	/// Decodes a frame in EXIF orientation, scaled so its longer side is at most `maxPixelSize`.
	/// Never scales up. Pass nil for `frameIndex` to use the largest frame.
	public static func decode(_ data: Data, frameIndex: Int? = nil, maxPixelSize: Int? = nil) -> RSBitmap? {
		withDecoder(data) { factory, decoder in
			guard let index = frameIndex ?? largestFrame(decoder)?.index, let frame = frame(decoder, index: index) else {
				return nil
			}
			return decode(factory, frame: frame, maxPixelSize: maxPixelSize)
		}
	}

	/// The bitmap encoded as PNG.
	public static func pngData(_ bitmap: RSBitmap) -> Data? {
		encode([bitmap], as: .png)
	}

	public enum ImageFormat: Sendable {
		case png, jpeg, tiff

		var containerFormat: GUID {
			switch self {
			case .png:
				return GUID_ContainerFormatPng
			case .jpeg:
				return GUID_ContainerFormatJpeg
			case .tiff:
				return GUID_ContainerFormatTiff
			}
		}

		var supportsMultipleFrames: Bool {
			self == .tiff
		}
	}

	/// Encodes one frame — or several, for TIFF — optionally tagged with an EXIF orientation (1...8).
	public static func encode(_ frames: [RSBitmap], as format: ImageFormat, exifOrientation: UInt16? = nil) -> Data? {
		withFactory { factory in
			encode(factory, frames: frames, format: format, exifOrientation: exifOrientation)
		}
	}
}

// MARK: - Decoding

private extension WICImaging {

	static func largestFrame(_ decoder: COMPointer<IWICBitmapDecoder>) -> FrameInfo? {
		var frameCount: UINT = 0
		guard succeeded(decoder.vtable.GetFrameCount(decoder.pointer, &frameCount)) else {
			return nil
		}

		var largest: FrameInfo?
		for index in 0..<Int(frameCount) {
			guard let frame = frame(decoder, index: index), let (width, height) = size(of: frame), width > 0, height > 0 else {
				continue
			}
			if let largest, max(largest.width, largest.height) >= max(width, height) {
				continue
			}
			largest = FrameInfo(index: index, width: width, height: height)
		}
		return largest
	}

	static func frame(_ decoder: COMPointer<IWICBitmapDecoder>, index: Int) -> COMPointer<IWICBitmapFrameDecode>? {
		var frame: UnsafeMutablePointer<IWICBitmapFrameDecode>?
		guard succeeded(decoder.vtable.GetFrame(decoder.pointer, UINT(index), &frame)) else {
			return nil
		}
		return COMPointer(frame)
	}

	static func size<Source>(of source: COMPointer<Source>) -> (Int, Int)? {
		let bitmapSource = source.reinterpreted(as: IWICBitmapSource.self)
		var width: UINT = 0
		var height: UINT = 0
		guard succeeded(bitmapSource.pointee.lpVtbl.pointee.GetSize(bitmapSource, &width, &height)) else {
			return nil
		}
		return (Int(width), Int(height))
	}

	static func decode(_ factory: COMPointer<IWICImagingFactory>, frame: COMPointer<IWICBitmapFrameDecode>, maxPixelSize: Int?) -> RSBitmap? {
		guard let (width, height) = size(of: frame), width > 0, height > 0 else {
			return nil
		}

		// Convert first, so scaling works on premultiplied pixels and doesn't bleed
		// the color of transparent pixels into their neighbors.
		var converterPointer: UnsafeMutablePointer<IWICFormatConverter>?
		guard succeeded(factory.vtable.CreateFormatConverter(factory.pointer, &converterPointer)), let converter = COMPointer(converterPointer) else {
			return nil
		}
		var pixelFormat = GUID_WICPixelFormat32bppPBGRA
		guard succeeded(converter.vtable.Initialize(converter.pointer, frame.reinterpreted(as: IWICBitmapSource.self), &pixelFormat, WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom)) else {
			return nil
		}
		var source: COMPointer<IWICBitmapSource> = converter.retainedAs(IWICBitmapSource.self)

		if let maxPixelSize, max(width, height) > maxPixelSize {
			let scale = Double(maxPixelSize) / Double(max(width, height))
			let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
			let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
			var scalerPointer: UnsafeMutablePointer<IWICBitmapScaler>?
			guard succeeded(factory.vtable.CreateBitmapScaler(factory.pointer, &scalerPointer)), let scaler = COMPointer(scalerPointer) else {
				return nil
			}
			guard succeeded(scaler.vtable.Initialize(scaler.pointer, source.pointer, UINT(scaledWidth), UINT(scaledHeight), WICBitmapInterpolationModeHighQualityCubic)) else {
				return nil
			}
			source = scaler.retainedAs(IWICBitmapSource.self)
		}

		let orientation = orientation(of: frame)
		if orientation != .up {
			// The flip rotator reads its source pixel by pixel, so give it a decoded bitmap.
			var cachedPointer: UnsafeMutablePointer<IWICBitmap>?
			guard succeeded(factory.vtable.CreateBitmapFromSource(factory.pointer, source.pointer, WICBitmapCacheOnLoad, &cachedPointer)), let cached = COMPointer(cachedPointer) else {
				return nil
			}
			var rotatorPointer: UnsafeMutablePointer<IWICBitmapFlipRotator>?
			guard succeeded(factory.vtable.CreateBitmapFlipRotator(factory.pointer, &rotatorPointer)), let rotator = COMPointer(rotatorPointer) else {
				return nil
			}
			guard succeeded(rotator.vtable.Initialize(rotator.pointer, cached.reinterpreted(as: IWICBitmapSource.self), orientation.transformOptions)) else {
				return nil
			}
			source = rotator.retainedAs(IWICBitmapSource.self)
		}

		return copyPixels(source)
	}

	static func copyPixels(_ source: COMPointer<IWICBitmapSource>) -> RSBitmap? {
		guard let (width, height) = size(of: source), width > 0, height > 0 else {
			return nil
		}
		let bytesPerRow = width * RSBitmap.bytesPerPixel
		let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
		guard !overflow, byteCount <= Int(UINT.max) else {
			return nil
		}
		var pixels = [UInt8](repeating: 0, count: byteCount)
		let result = pixels.withUnsafeMutableBufferPointer { buffer in
			source.vtable.CopyPixels(source.pointer, nil, UINT(bytesPerRow), UINT(byteCount), buffer.baseAddress)
		}
		guard succeeded(result) else {
			return nil
		}
		return RSBitmap(width: width, height: height, pixels: pixels)
	}
}

// MARK: - Orientation

private extension WICImaging {

	/// EXIF orientation (TIFF tag 274), the same values as CGImagePropertyOrientation.
	enum Orientation: UInt16 {
		case up = 1, upMirrored, down, downMirrored, leftMirrored, right, rightMirrored, left

		var swapsWidthAndHeight: Bool {
			switch self {
			case .leftMirrored, .right, .rightMirrored, .left:
				return true
			case .up, .upMirrored, .down, .downMirrored:
				return false
			}
		}

		/// The transform that displays the stored pixels upright. WIC flips first, then rotates clockwise.
		var transformOptions: WICBitmapTransformOptions {
			switch self {
			case .up:
				return WICBitmapTransformRotate0
			case .upMirrored:
				return WICBitmapTransformFlipHorizontal
			case .down:
				return WICBitmapTransformRotate180
			case .downMirrored:
				return WICBitmapTransformFlipVertical
			case .leftMirrored:
				return WICBitmapTransformOptions(rawValue: WICBitmapTransformRotate270.rawValue | WICBitmapTransformFlipHorizontal.rawValue)
			case .right:
				return WICBitmapTransformRotate90
			case .rightMirrored:
				return WICBitmapTransformOptions(rawValue: WICBitmapTransformRotate90.rawValue | WICBitmapTransformFlipHorizontal.rawValue)
			case .left:
				return WICBitmapTransformRotate270
			}
		}
	}

	/// The photo metadata policy name first, which covers JPEG, TIFF, and HEIF,
	/// then the raw EXIF locations for decoders that don't map it.
	static let orientationQueries = ["System.Photo.Orientation", "/app1/ifd/{ushort=274}", "/ifd/{ushort=274}"]

	static let vtUI2: VARTYPE = 18 // VT_UI2

	static func orientation(of frame: COMPointer<IWICBitmapFrameDecode>) -> Orientation {
		var readerPointer: UnsafeMutablePointer<IWICMetadataQueryReader>?
		guard succeeded(frame.vtable.GetMetadataQueryReader(frame.pointer, &readerPointer)), let reader = COMPointer(readerPointer) else {
			return .up
		}

		for query in orientationQueries {
			var value = PROPVARIANT()
			let result = query.withCString(encodedAs: UTF16.self) { name in
				reader.vtable.GetMetadataByName(reader.pointer, name, &value)
			}
			defer {
				PropVariantClear(&value)
			}
			guard succeeded(result) else {
				continue
			}
			// PROPVARIANT is a tagged union: the type at offset 0, the value at offset 8.
			let (type, rawValue) = withUnsafeBytes(of: &value) { bytes in
				(bytes.load(fromByteOffset: 0, as: VARTYPE.self), bytes.load(fromByteOffset: 8, as: UInt16.self))
			}
			if type == vtUI2, let orientation = Orientation(rawValue: rawValue) {
				return orientation
			}
		}
		return .up
	}
}

// MARK: - Encoding

private extension WICImaging {

	static func encode(_ factory: COMPointer<IWICImagingFactory>, frames: [RSBitmap], format: ImageFormat, exifOrientation: UInt16?) -> Data? {
		guard !frames.isEmpty, frames.count == 1 || format.supportsMultipleFrames else {
			return nil
		}

		var streamPointer: UnsafeMutablePointer<IStream>?
		guard succeeded(CreateStreamOnHGlobal(nil, true, &streamPointer)), let stream = COMPointer(streamPointer) else {
			return nil
		}

		var encoderPointer: UnsafeMutablePointer<IWICBitmapEncoder>?
		var containerFormat = format.containerFormat
		guard succeeded(factory.vtable.CreateEncoder(factory.pointer, &containerFormat, nil, &encoderPointer)), let encoder = COMPointer(encoderPointer) else {
			return nil
		}
		guard succeeded(encoder.vtable.Initialize(encoder.pointer, stream.pointer, WICBitmapEncoderNoCache)) else {
			return nil
		}

		for bitmap in frames {
			guard writeFrame(factory, encoder: encoder, bitmap: bitmap, exifOrientation: exifOrientation) else {
				return nil
			}
		}
		guard succeeded(encoder.vtable.Commit(encoder.pointer)) else {
			return nil
		}

		// The HGLOBAL can be larger than what was written; the stream position is the length.
		var position = ULARGE_INTEGER()
		guard succeeded(stream.vtable.Seek(stream.pointer, LARGE_INTEGER(), DWORD(STREAM_SEEK_CUR.rawValue), &position)) else {
			return nil
		}
		var global: HGLOBAL?
		guard succeeded(GetHGlobalFromStream(stream.pointer, &global)), let global, let bytes = GlobalLock(global) else {
			return nil
		}
		defer {
			GlobalUnlock(global)
		}
		return Data(bytes: bytes, count: Int(position.QuadPart))
	}

	static func writeFrame(_ factory: COMPointer<IWICImagingFactory>, encoder: COMPointer<IWICBitmapEncoder>, bitmap: RSBitmap, exifOrientation: UInt16?) -> Bool {
		var frameEncodePointer: UnsafeMutablePointer<IWICBitmapFrameEncode>?
		var propertiesPointer: UnsafeMutablePointer<IPropertyBag2>?
		guard succeeded(encoder.vtable.CreateNewFrame(encoder.pointer, &frameEncodePointer, &propertiesPointer)), let frameEncode = COMPointer(frameEncodePointer) else {
			return false
		}
		let properties = COMPointer(propertiesPointer)
		guard succeeded(frameEncode.vtable.Initialize(frameEncode.pointer, properties?.pointer)) else {
			return false
		}
		guard succeeded(frameEncode.vtable.SetSize(frameEncode.pointer, UINT(bitmap.width), UINT(bitmap.height))) else {
			return false
		}

		if let exifOrientation {
			var writerPointer: UnsafeMutablePointer<IWICMetadataQueryWriter>?
			guard succeeded(frameEncode.vtable.GetMetadataQueryWriter(frameEncode.pointer, &writerPointer)), let writer = COMPointer(writerPointer) else {
				return false
			}
			var value = PROPVARIANT()
			withUnsafeMutableBytes(of: &value) { bytes in
				bytes.storeBytes(of: vtUI2, toByteOffset: 0, as: VARTYPE.self)
				bytes.storeBytes(of: exifOrientation, toByteOffset: 8, as: UInt16.self)
			}
			let result = "System.Photo.Orientation".withCString(encodedAs: UTF16.self) { name in
				writer.vtable.SetMetadataByName(writer.pointer, name, &value)
			}
			guard succeeded(result) else {
				return false
			}
		}

		// WriteSource converts to a pixel format the encoder takes, such as straight alpha for PNG.
		var pixels = bitmap.pixels
		var pixelFormat = GUID_WICPixelFormat32bppPBGRA
		var sourcePointer: UnsafeMutablePointer<IWICBitmap>?
		let createResult = pixels.withUnsafeMutableBufferPointer { buffer in
			factory.vtable.CreateBitmapFromMemory(factory.pointer, UINT(bitmap.width), UINT(bitmap.height), &pixelFormat, UINT(bitmap.bytesPerRow), UINT(buffer.count), buffer.baseAddress, &sourcePointer)
		}
		guard succeeded(createResult), let source = COMPointer(sourcePointer) else {
			return false
		}
		guard succeeded(frameEncode.vtable.WriteSource(frameEncode.pointer, source.reinterpreted(as: IWICBitmapSource.self), nil)) else {
			return false
		}
		return succeeded(frameEncode.vtable.Commit(frameEncode.pointer))
	}
}

// MARK: - COM

private extension WICImaging {

	static func succeeded(_ result: HRESULT) -> Bool {
		result >= 0
	}

	/// Runs `body` with a WIC factory, initializing COM on this thread for the call if needed.
	static func withFactory<T>(_ body: (COMPointer<IWICImagingFactory>) -> T?) -> T? {
		let initializeResult = CoInitializeEx(nil, DWORD(COINIT_MULTITHREADED.rawValue))
		// S_OK and S_FALSE need balancing. RPC_E_CHANGED_MODE means the thread is already
		// in a single-threaded apartment, such as a UI thread, which WIC works in too.
		defer {
			if succeeded(initializeResult) {
				CoUninitialize()
			}
		}

		var classID = CLSID_WICImagingFactory
		var interfaceID = IID_IWICImagingFactory
		var factoryPointer: LPVOID?
		guard succeeded(CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &interfaceID, &factoryPointer)),
			  let factory = COMPointer(factoryPointer?.assumingMemoryBound(to: IWICImagingFactory.self)) else {
			return nil
		}
		return body(factory)
	}

	/// Runs `body` with a decoder reading `data`. The decoder reads straight from `data`'s
	/// bytes, so it — and everything made from it — must not outlive `body`.
	static func withDecoder<T>(_ data: Data, _ body: (COMPointer<IWICImagingFactory>, COMPointer<IWICBitmapDecoder>) -> T?) -> T? {
		guard !data.isEmpty, data.count <= Int(DWORD.max) else {
			return nil
		}
		return withFactory { factory in
			var bytes = [UInt8](data)
			return bytes.withUnsafeMutableBufferPointer { buffer -> T? in
				var streamPointer: UnsafeMutablePointer<IWICStream>?
				guard succeeded(factory.vtable.CreateStream(factory.pointer, &streamPointer)), let stream = COMPointer(streamPointer) else {
					return nil
				}
				guard succeeded(stream.vtable.InitializeFromMemory(stream.pointer, buffer.baseAddress, DWORD(buffer.count))) else {
					return nil
				}
				var decoderPointer: UnsafeMutablePointer<IWICBitmapDecoder>?
				guard succeeded(factory.vtable.CreateDecoderFromStream(factory.pointer, stream.reinterpreted(as: IStream.self), nil, WICDecodeMetadataCacheOnDemand, &decoderPointer)),
					  let decoder = COMPointer(decoderPointer) else {
					return nil
				}
				return body(factory, decoder)
			}
		}
	}
}

/// Owns one reference to a COM object and releases it when done.
private final class COMPointer<Interface> {

	let pointer: UnsafeMutablePointer<Interface>

	/// Takes ownership of a reference returned through an out parameter.
	init?(_ pointer: UnsafeMutablePointer<Interface>?) {
		guard let pointer else {
			return nil
		}
		self.pointer = pointer
	}

	deinit {
		let unknown = UnsafeMutablePointer<IUnknown>(OpaquePointer(pointer))
		_ = unknown.pointee.lpVtbl.pointee.Release(unknown)
	}

	/// The same object seen as a base interface it derives from, such as IWICBitmapSource.
	/// Valid only while this pointer is alive.
	func reinterpreted<Base>(as: Base.Type) -> UnsafeMutablePointer<Base> {
		UnsafeMutablePointer<Base>(OpaquePointer(pointer))
	}

	/// A new owning pointer to the same object as a base interface.
	func retainedAs<Base>(_ type: Base.Type) -> COMPointer<Base> {
		let unknown = UnsafeMutablePointer<IUnknown>(OpaquePointer(pointer))
		_ = unknown.pointee.lpVtbl.pointee.AddRef(unknown)
		// A non-nil pointer always makes a COMPointer.
		return COMPointer<Base>(reinterpreted(as: type)).unsafelyUnwrapped
	}
}

// Each WIC interface's vtable, so call sites read `object.vtable.Method(object.pointer, ...)`.
private extension COMPointer where Interface == IWICImagingFactory {
	var vtable: IWICImagingFactoryVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapDecoder {
	var vtable: IWICBitmapDecoderVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapFrameDecode {
	var vtable: IWICBitmapFrameDecodeVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapSource {
	var vtable: IWICBitmapSourceVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICFormatConverter {
	var vtable: IWICFormatConverterVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapScaler {
	var vtable: IWICBitmapScalerVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapFlipRotator {
	var vtable: IWICBitmapFlipRotatorVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICMetadataQueryReader {
	var vtable: IWICMetadataQueryReaderVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICStream {
	var vtable: IWICStreamVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IStream {
	var vtable: IStreamVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapEncoder {
	var vtable: IWICBitmapEncoderVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICMetadataQueryWriter {
	var vtable: IWICMetadataQueryWriterVtbl { pointer.pointee.lpVtbl.pointee }
}
private extension COMPointer where Interface == IWICBitmapFrameEncode {
	var vtable: IWICBitmapFrameEncodeVtbl { pointer.pointee.lpVtbl.pointee }
}

#endif
