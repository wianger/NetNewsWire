//
//  FaviconGenerator.swift
//  Images
//
//  Created by Maurice Parker on 4/29/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import Foundation
import RSCore
import Account

@MainActor public final class FaviconGenerator {
	public static let shared = FaviconGenerator()

	/// The template image used to synthesize colored placeholders. The app must
	/// set this at launch (see Mac/iOS AppDelegate) before any feed is shown.
	public static var templateImage: RSImage?

	private var cache = [String: IconImage]() // feedURL: IconImage

	private init() {
		NotificationCenter.default.addMainActorObserver(self, name: .lowMemory, object: nil) { $0.handleLowMemory($1) }
		NotificationCenter.default.addMainActorObserver(self, name: .appDidGoToBackground, object: nil) { $0.handleAppDidGoToBackground($1) }
	}

	func handleLowMemory(_ notification: Notification) {
		cache.removeAll()
	}

	func handleAppDidGoToBackground(_ notification: Notification) {
		cache.removeAll()
	}

	public func favicon(_ feed: Feed) -> IconImage {
		guard let template = Self.templateImage else {
			preconditionFailure("FaviconGenerator.templateImage must be set at app launch")
		}

		if let favicon = cache[feed.url] {
			return favicon
		}

		let colorHash = ColorHash(feed.url)
#if os(Windows)
		let maskColor = colorHash.color
#else
		let maskColor = colorHash.color.cgColor
#endif
		if let favicon = template.maskWithColor(color: maskColor) {
			let iconImage = IconImage(favicon, isBackgroundSuppressed: true)
			cache[feed.url] = iconImage
			return iconImage
		} else {
			return IconImage(template, isBackgroundSuppressed: true)
		}
	}
}
