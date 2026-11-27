//
//  CoreService+URLs.swift
//  CoreService
//
//  What a URL the app was opened with means, as the Mac's getURL Apple event handler
//  (Mac/Scripting/AppDelegate+Scriptability.swift) decides: a feed to add for feed:, feeds:,
//  x-netnewswire-feed:, and plain web URLs; a theme for netnewswire://theme/?url=…;
//  nothing for other netnewswire: URLs.
//

import Foundation
import RSCore

extension CoreService {

	func interpretOpenedURL(_ params: OpenedURLParams) -> OpenedURLAction {
		var urlString = params.url.trimmingCharacters(in: .whitespacesAndNewlines)

		if urlString.lowercased().hasPrefix("netnewswire://theme/") {
			guard let queryItems = URLComponents(string: urlString)?.queryItems, let themeURL = queryItems.first(where: { $0.name == "url" })?.value, URL(string: themeURL) != nil else {
				return OpenedURLAction(kind: .ignore, url: nil)
			}
			return OpenedURLAction(kind: .installTheme, url: themeURL)
		}

		// Other netnewswire: URLs aren't feeds.
		if urlString.lowercased().hasPrefix("netnewswire:") {
			return OpenedURLAction(kind: .ignore, url: nil)
		}

		// A scheme only NetNewsWire handles, so a page can open it here whatever the default feed reader.
		let nnwScheme = "x-netnewswire-feed:"
		if urlString.lowercased().hasPrefix(nnwScheme) {
			urlString = "feed:" + urlString.dropFirst(nnwScheme.count)
		}

		let normalized = urlString.normalizedURL
		guard normalized.mayBeURL else {
			return OpenedURLAction(kind: .ignore, url: nil)
		}
		return OpenedURLAction(kind: .addFeed, url: normalized)
	}
}

struct OpenedURLParams: Decodable {
	let url: String
}

struct OpenedURLAction: Encodable {
	enum Kind: String, Encodable {
		/// Show Add Feed with `url`.
		case addFeed
		/// Download and install the theme at `url`.
		case installTheme
		case ignore
	}

	let kind: Kind
	let url: String?
}
