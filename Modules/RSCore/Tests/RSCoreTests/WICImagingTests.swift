//
//  WICImagingTests.swift
//  RSCoreTests
//
//  The Windows image layer: WIC decoding, scaling, orientation, and encoding, and
//  RSImage behavior that matches ImageIO's on Apple platforms.
//

#if os(Windows)

import Foundation
import Testing
@testable import RSCore

@Suite struct WICImagingTests {

	// MARK: - Round trips

	@Test func pngRoundTripKeepsPixelsExactly() throws {
		let bitmap = try #require(makeBitmap(width: 3, height: 2) { x, y in
			[UInt8(x * 80), UInt8(y * 120), 200, 255]
		})
		let pngData = try #require(WICImaging.pngData(bitmap))
		#expect(Array(pngData.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
		#expect(WICImaging.decode(pngData) == bitmap)
	}

	@Test func pngRoundTripKeepsPremultipliedAlpha() throws {
		let bitmap = try #require(makeBitmap(width: 2, height: 2) { _, _ in [0, 0, 128, 128] })
		let pngData = try #require(WICImaging.pngData(bitmap))
		let decoded = try #require(WICImaging.decode(pngData))
		#expect(decoded.pixels[3] == 128)
		#expect(abs(Int(decoded.pixels[2]) - 128) <= 1)
	}

	@Test func garbageIsNotAnImage() {
		let garbage = Data("not an image".utf8)
		#expect(WICImaging.decode(garbage) == nil)
		#expect(WICImaging.largestFrame(garbage) == nil)
		#expect(RSImage(data: garbage) == nil)
		#expect(RSImage.scaledImageData(garbage, maxPixelSize: 32) == nil)
		#expect(WICImaging.decode(Data()) == nil)
	}

	// MARK: - Orientation

	/// A red block in the stored top-left quarter must show in the displayed quarter
	/// that EXIF orientation says, and quarter turns must swap width and height.
	@Test(arguments: [
		(UInt16(1), Corner.topLeft), (2, .topRight), (3, .bottomRight), (4, .bottomLeft),
		(5, .topLeft), (6, .topRight), (7, .bottomRight), (8, .bottomLeft)
	])
	func decodesInEXIFOrientation(orientation: UInt16, expectedCorner: Corner) throws {
		let width = 80
		let height = 120
		let bitmap = try #require(makeBitmap(width: width, height: height) { x, y in
			x < width / 2 && y < height / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255]
		})
		let jpegData = try #require(WICImaging.encode([bitmap], as: .jpeg, exifOrientation: orientation))

		let swapsSides = orientation >= 5
		#expect(WICImaging.isRotatedQuarterTurn(jpegData, frameIndex: 0) == swapsSides)

		let decoded = try #require(WICImaging.decode(jpegData))
		#expect(decoded.width == (swapsSides ? height : width))
		#expect(decoded.height == (swapsSides ? width : height))
		for corner in Corner.allCases {
			let isRed = isMostlyRed(decoded, at: corner)
			#expect(isRed == (corner == expectedCorner), "orientation \(orientation): \(corner)")
		}
	}

	// MARK: - Frames and scaling

	@Test func largestFrameOfMultiFrameTIFF() throws {
		let small = try #require(makeBitmap(width: 16, height: 16) { _, _ in [0, 0, 0, 255] })
		let large = try #require(makeBitmap(width: 64, height: 32) { _, _ in [255, 255, 255, 255] })
		let tiffData = try #require(WICImaging.encode([small, large, small], as: .tiff))

		#expect(WICImaging.frameCount(tiffData) == 3)
		let largestFrame = try #require(WICImaging.largestFrame(tiffData))
		#expect(largestFrame.index == 1)
		#expect(largestFrame.width == 64 && largestFrame.height == 32)
		let pixelSize = try #require(RSImage.largestFramePixelSize(tiffData))
		#expect(pixelSize.width == 64 && pixelSize.height == 32)

		let image = try #require(RSImage(data: tiffData))
		#expect(image.size == CGSize(width: 64, height: 32))
	}

	@Test func decodeScalesDownKeepingAspectRatioButNeverUp() throws {
		let bitmap = try #require(makeBitmap(width: 200, height: 100) { _, _ in [10, 20, 30, 255] })
		let pngData = try #require(WICImaging.pngData(bitmap))

		let scaled = try #require(WICImaging.decode(pngData, maxPixelSize: 50))
		#expect(scaled.width == 50 && scaled.height == 25)

		let unscaled = try #require(WICImaging.decode(pngData, maxPixelSize: 1000))
		#expect(unscaled.width == 200 && unscaled.height == 100)
	}

	@Test func scaledImageDataReturnsSmallSingleFrameImagesUnchanged() throws {
		let bitmap = try #require(makeBitmap(width: 16, height: 16) { _, _ in [1, 2, 3, 255] })
		let pngData = try #require(WICImaging.pngData(bitmap))
		#expect(RSImage.scaledImageData(pngData, maxPixelSize: 32) == pngData)
	}

	@Test func scaledImageDataShrinksLargeImagesToPNG() throws {
		let bitmap = try #require(makeBitmap(width: 120, height: 60) { _, _ in [1, 2, 3, 255] })
		let jpegData = try #require(WICImaging.encode([bitmap], as: .jpeg))
		let scaledData = try #require(RSImage.scaledImageData(jpegData, maxPixelSize: 30))
		#expect(Array(scaledData.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
		let pixelSize = try #require(RSImage.largestFramePixelSize(scaledData))
		#expect(pixelSize.width == 30 && pixelSize.height == 15)
	}

	@Test func scaledImageDataExtractsTheLargestFrame() throws {
		let small = try #require(makeBitmap(width: 8, height: 8) { _, _ in [0, 0, 0, 255] })
		let large = try #require(makeBitmap(width: 24, height: 24) { _, _ in [0, 0, 0, 255] })
		let tiffData = try #require(WICImaging.encode([small, large], as: .tiff))
		let scaledData = try #require(RSImage.scaledImageData(tiffData, maxPixelSize: 32))
		#expect(WICImaging.frameCount(scaledData) == 1)
		let pixelSize = try #require(RSImage.largestFramePixelSize(scaledData))
		#expect(pixelSize.width == 24 && pixelSize.height == 24)
	}

	// MARK: - Luminance, as CGImageLuminanceTests checks on Apple platforms

	@Test func whiteImageWithTransparencyIsBright() throws {
		let image = try makeImage(opaqueFraction: 0.5, white: true)
		#expect(image.calculateLuminanceType() == .bright)
	}

	@Test func fullyWhiteOpaqueIsBright() throws {
		#expect(try makeImage(opaqueFraction: 1, white: true).calculateLuminanceType() == .bright)
	}

	@Test func fullyBlackOpaqueIsDark() throws {
		#expect(try makeImage(opaqueFraction: 1, white: false).calculateLuminanceType() == .dark)
	}

	@Test func midGrayOpaqueIsRegular() throws {
		let bitmap = try #require(makeBitmap(width: 100, height: 100) { _, _ in [128, 128, 128, 255] })
		#expect(RSImage(bitmap: bitmap).calculateLuminanceType() == .regular)
	}

	@Test func fullyTransparentIsRegular() throws {
		#expect(try makeImage(opaqueFraction: 0, white: true).calculateLuminanceType() == .regular)
	}

	// MARK: - Masking

	@Test func maskWithColorFillsByAlpha() throws {
		let bitmap = try #require(makeBitmap(width: 2, height: 1) { x, _ in x == 0 ? [0, 0, 0, 255] : [0, 0, 0, 0] })
		let masked = try #require(RSImage(bitmap: bitmap).maskWithColor(color: RSColor(red: 1, green: 0.5, blue: 0, alpha: 1)))
		#expect(Array(masked.bitmap.pixels[0..<4]) == [0, 128, 255, 255])
		#expect(Array(masked.bitmap.pixels[4..<8]) == [0, 0, 0, 0])
	}

	@Test func hueSaturationBrightnessMatchesAppKit() {
		let color = RSColor(hue: 0.5, saturation: 1, brightness: 1, alpha: 1)
		#expect(color.red == 0 && color.green == 1 && color.blue == 1)
		let red = RSColor(hue: 1, saturation: 1, brightness: 1, alpha: 1)
		#expect(red.red == 1 && red.green == 0 && red.blue == 0)
	}
}

// MARK: - Helpers

enum Corner: CaseIterable, Sendable {
	case topLeft, topRight, bottomLeft, bottomRight
}

private extension WICImagingTests {

	func makeBitmap(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) -> RSBitmap? {
		var pixels = [UInt8]()
		pixels.reserveCapacity(width * height * RSBitmap.bytesPerPixel)
		for y in 0..<height {
			for x in 0..<width {
				pixels.append(contentsOf: pixel(x, y))
			}
		}
		return RSBitmap(width: width, height: height, pixels: pixels)
	}

	/// The bottom `opaqueFraction` of rows opaque white or black; the rest transparent.
	func makeImage(opaqueFraction: Double, white: Bool) throws -> RSImage {
		let size = 100
		let firstOpaqueRow = size - Int(Double(size) * opaqueFraction)
		let value: UInt8 = white ? 255 : 0
		let bitmap = try #require(makeBitmap(width: size, height: size) { _, y in
			y >= firstOpaqueRow ? [value, value, value, 255] : [0, 0, 0, 0]
		})
		return RSImage(bitmap: bitmap)
	}

	/// Samples the middle of a quarter of the bitmap.
	func isMostlyRed(_ bitmap: RSBitmap, at corner: Corner) -> Bool {
		let x = corner == .topLeft || corner == .bottomLeft ? bitmap.width / 4 : bitmap.width * 3 / 4
		let y = corner == .topLeft || corner == .topRight ? bitmap.height / 4 : bitmap.height * 3 / 4
		let offset = y * bitmap.bytesPerRow + x * RSBitmap.bytesPerPixel
		return bitmap.pixels[offset + 2] > 200 && bitmap.pixels[offset] < 60
	}
}

#endif
