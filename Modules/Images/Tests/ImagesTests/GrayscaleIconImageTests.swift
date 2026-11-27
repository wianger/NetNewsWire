//
//  GrayscaleIconImageTests.swift
//  ImagesTests
//
//  Created by Brent Simmons on 11/9/26.
//

import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Testing
import RSCore
@testable import Images

@Suite struct GrayscaleIconImageTests {

	@Test func redIconBecomesGrayAndKeepsAlpha() throws {
		let iconImage = IconImage(try halfTransparentRedImage())
		let grayscaleIconImage = iconImage.grayscaleIconImage
		#expect(grayscaleIconImage === iconImage.grayscaleIconImage)

		let pixel = try firstPixel(grayscaleIconImage.image)
		#expect(pixel.red == pixel.green)
		#expect(pixel.green == pixel.blue)
		#expect(pixel.red > 0)
		#expect(pixel.alpha == 128)
	}
}

private extension GrayscaleIconImageTests {

	static let dimension = 2

#if os(Windows)
	func halfTransparentRedImage() throws -> RSImage {
		// Premultiplied BGRA: red at alpha 128.
		let pixel: [UInt8] = [0, 0, 128, 128]
		let bitmap = try #require(RSBitmap(width: Self.dimension, height: Self.dimension, pixels: Array([[UInt8]](repeating: pixel, count: Self.dimension * Self.dimension).joined())))
		return RSImage(bitmap: bitmap)
	}

	func firstPixel(_ image: RSImage) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
		let pixels = image.bitmap.pixels
		return (pixels[2], pixels[1], pixels[0], pixels[3])
	}
#else
	func halfTransparentRedImage() throws -> RSImage {
		let context = try #require(bitmapContext())
		context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 128.0 / 255.0))
		context.fill(CGRect(x: 0, y: 0, width: Self.dimension, height: Self.dimension))
		let cgImage = try #require(context.makeImage())
		#if os(macOS)
		return NSImage(cgImage: cgImage, size: CGSize(width: Self.dimension, height: Self.dimension))
		#else
		return UIImage(cgImage: cgImage)
		#endif
	}

	func firstPixel(_ image: RSImage) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
		#if os(macOS)
		let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
		#else
		let cgImage = try #require(image.cgImage)
		#endif
		let context = try #require(bitmapContext())
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: Self.dimension, height: Self.dimension))
		let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: 4)
		return (pixels[0], pixels[1], pixels[2], pixels[3])
	}

	func bitmapContext() -> CGContext? {
		guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
			return nil
		}
		let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
		return CGContext(data: nil, width: Self.dimension, height: Self.dimension, bitsPerComponent: 8, bytesPerRow: Self.dimension * 4, space: colorSpace, bitmapInfo: bitmapInfo)
	}
#endif
}
