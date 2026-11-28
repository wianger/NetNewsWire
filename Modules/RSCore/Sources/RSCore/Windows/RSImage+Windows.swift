//
//  RSImage+Windows.swift
//  RSCore
//
//  RSImage and RSColor for Windows: decoded pixels the WinUI layer turns into a
//  SoftwareBitmap, with the same decoding, scaling, and luminance behavior as on
//  Apple platforms. Decoding is done by WIC (see WICImaging.swift).
//

#if os(Windows)

import Foundation
import WinSDK
#if canImport(os)
import os
#endif

private let RSImageLogger = Logger(subsystem: Logger.nnwSubsystem, category: "RSImage")

/// An immutable decoded image. One pixel is one device-independent unit, as for an
/// NSImage made from a 72 dpi bitmap; the UI layer scales for the display.
public final class RSImage: Sendable {

	public let bitmap: RSBitmap

	public var size: CGSize {
		CGSize(width: bitmap.width, height: bitmap.height)
	}

	public init(bitmap: RSBitmap) {
		self.bitmap = bitmap
	}

	/// Decodes the largest frame, upright.
	public convenience init?(data: Data) {
		guard let bitmap = WICImaging.decode(data) else {
			return nil
		}
		self.init(bitmap: bitmap)
	}

	/// Returns data as PNG.
	public func pngData() -> Data? {
		WICImaging.pngData(bitmap)
	}

	/// Returns a data representation of the image, as PNG.
	public func dataRepresentation() -> Data? {
		pngData()
	}

	/// The image filled with `color` where it is opaque: its alpha used as a mask.
	public func maskWithColor(color: RSColor) -> RSImage? {
		let (red, green, blue, alpha) = color.premultipliedBGRAComponents
		var pixels = bitmap.pixels
		for offset in stride(from: 0, to: pixels.count, by: RSBitmap.bytesPerPixel) {
			let coverage = UInt16(pixels[offset + 3])
			pixels[offset] = UInt8((UInt16(blue) * coverage + 127) / 255)
			pixels[offset + 1] = UInt8((UInt16(green) * coverage + 127) / 255)
			pixels[offset + 2] = UInt8((UInt16(red) * coverage + 127) / 255)
			pixels[offset + 3] = UInt8((UInt16(alpha) * coverage + 127) / 255)
		}
		guard let maskedBitmap = RSBitmap(width: bitmap.width, height: bitmap.height, pixels: pixels) else {
			return nil
		}
		return RSImage(bitmap: maskedBitmap)
	}

	/// Asynchronously initializes an image from data.
	public static func image(data: Data) async -> RSImage? {
		await withCheckedContinuation { continuation in
			RSImage.image(with: data) { image in
				continuation.resume(returning: image)
			}
		}
	}

	/// Asynchronously initializes an image from data, calling `imageResultBlock` on the main queue.
	public static func image(with data: Data, imageResultBlock: @escaping ImageResultBlock) {
		DispatchQueue.global().async {
			let image = RSImage(data: data)
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					imageResultBlock(image)
				}
			}
		}
	}

	/// Makes an image whose pixels are already decoded. On Windows every RSImage is.
	/// Call it off the main thread.
	public static func decodedImage(data: Data) -> RSImage? {
		RSImage(data: data)
	}

	/// Pixel dimensions of the largest frame, read from the image header without decoding.
	/// Returns nil if the data can't be read as an image.
	public static func largestFramePixelSize(_ data: Data) -> (width: Int, height: Int)? {
		guard let largestFrame = WICImaging.largestFrame(data) else {
			return nil
		}
		return (width: largestFrame.width, height: largestFrame.height)
	}

	/// Scales image data down to maxPixelSize and returns the result encoded as PNG.
	/// If the image is a single frame already at or below maxPixelSize, returns
	/// the original data unchanged. For multi-image sources (like ICO), extracts
	/// the largest frame. Returns nil if the data can't be decoded as an image —
	/// including SVG, which WIC doesn't read.
	public static func scaledImageData(_ data: Data, maxPixelSize: Int) -> Data? {
		guard let frameCount = WICImaging.frameCount(data), let largestFrame = WICImaging.largestFrame(data) else {
			return nil
		}

		let largestMaxDimension = max(largestFrame.width, largestFrame.height)
		let needsResize = largestMaxDimension > maxPixelSize
		let isMultiImage = frameCount > 1

		if !needsResize && !isMultiImage {
			RSImageLogger.info("Image already small enough: \(largestFrame.width, privacy: .public)x\(largestFrame.height, privacy: .public) <= \(maxPixelSize, privacy: .public)px max")
			return data
		}

		guard let bitmap = WICImaging.decode(data, frameIndex: largestFrame.index, maxPixelSize: maxPixelSize), let scaledData = WICImaging.pngData(bitmap) else {
			return nil
		}

		if needsResize {
			RSImageLogger.info("Resized image from \(largestFrame.width, privacy: .public)x\(largestFrame.height, privacy: .public) to \(bitmap.width, privacy: .public)x\(bitmap.height, privacy: .public)")
		} else {
			RSImageLogger.info("Extracted largest frame (\(largestFrame.width, privacy: .public)x\(largestFrame.height, privacy: .public)) from multi-image source (\(frameCount, privacy: .public) frames)")
		}

		return scaledData
	}

	// MARK: - Luminance

	/// Classifies the image as bright, dark, or regular, the same way `CGImage.calculateLuminanceType()` does:
	/// sampled at 20x20 nearest-neighbor, ignoring transparent pixels, un-premultiplied.
	public func calculateLuminanceType() -> ImageLuminanceType? {
		let sampleSide = 20
		let totalPixels = sampleSide * sampleSide

		var totalLuminance = 0.0
		var pixelsProcessed = 0

		for i in 0..<totalPixels {
			let sampleX = i % sampleSide
			let sampleY = i / sampleSide
			let x = min(bitmap.width - 1, (2 * sampleX + 1) * bitmap.width / (2 * sampleSide))
			let y = min(bitmap.height - 1, (2 * sampleY + 1) * bitmap.height / (2 * sampleSide))
			let offset = y * bitmap.bytesPerRow + x * RSBitmap.bytesPerPixel

			let a = bitmap.pixels[offset + 3]
			if a == 0 {
				// Transparent pixels carry no color, so skip them.
				continue
			}

			let r = Double(bitmap.pixels[offset + 2]) * 255.0 / Double(a)
			let g = Double(bitmap.pixels[offset + 1]) * 255.0 / Double(a)
			let b = Double(bitmap.pixels[offset]) * 255.0 / Double(a)

			totalLuminance += 0.299 * r + 0.587 * g + 0.114 * b
			pixelsProcessed += 1

			// Early exit after the first quarter of the samples, as on Apple platforms.
			if pixelsProcessed == totalPixels / 4 {
				let currentAverage = totalLuminance / Double(pixelsProcessed)
				if currentAverage < 30 {
					return .dark
				} else if currentAverage > 190 {
					return .bright
				}
			}
		}

		guard pixelsProcessed > 0 else {
			return .regular
		}

		let averageLuminance = totalLuminance / Double(pixelsProcessed)
		if averageLuminance < 40 {
			return .dark
		} else if averageLuminance > 180 {
			return .bright
		}
		return .regular
	}
}

/// An sRGB color with components from 0 to 1.
public struct RSColor: Sendable, Hashable {

	public let red: CGFloat
	public let green: CGFloat
	public let blue: CGFloat
	public let alpha: CGFloat

	public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	public init(white: CGFloat, alpha: CGFloat) {
		self.init(red: white, green: white, blue: white, alpha: alpha)
	}

	public init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
		let h = (hue - hue.rounded(.down)) * 6
		let sector = Int(h) % 6
		let fraction = h - CGFloat(sector)
		let p = brightness * (1 - saturation)
		let q = brightness * (1 - saturation * fraction)
		let t = brightness * (1 - saturation * (1 - fraction))
		let v = brightness
		switch sector {
		case 0: self.init(red: v, green: t, blue: p, alpha: alpha)
		case 1: self.init(red: q, green: v, blue: p, alpha: alpha)
		case 2: self.init(red: p, green: v, blue: t, alpha: alpha)
		case 3: self.init(red: p, green: q, blue: v, alpha: alpha)
		case 4: self.init(red: t, green: p, blue: v, alpha: alpha)
		default: self.init(red: v, green: p, blue: q, alpha: alpha)
		}
	}

	/// Like the system secondary label color: gray at partial opacity, readable on light and dark backgrounds.
	public static let secondaryLabel = RSColor(white: 0.5, alpha: 0.85)

	/// Components scaled to 0...255 and premultiplied by alpha.
	var premultipliedBGRAComponents: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
		func byte(_ value: CGFloat) -> UInt8 {
			UInt8((min(max(value, 0), 1) * 255).rounded())
		}
		let clampedAlpha = min(max(alpha, 0), 1)
		return (byte(red * clampedAlpha), byte(green * clampedAlpha), byte(blue * clampedAlpha), byte(clampedAlpha))
	}
}

#endif
