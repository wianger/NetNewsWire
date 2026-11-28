//
//  CoreService+Thumbnails.swift
//  CoreService
//
//  Timeline thumbnails, as the Mac timeline gets them: ArticleThumbnailFinder picks each
//  article's image (articles.fetch returns it when asked for a thumbnail mode), and
//  ThumbnailDownloader downloads and decodes it at display size, off the main thread,
//  newest first. `thumbnails.get` answers at once; a `thumbnailsChanged` event follows
//  when a pending image is ready, or when an image fails and the finder picks another.
//

import Foundation
import RSCore
import Articles
import Account
import Images

extension CoreService {

	/// The image if it's decoded, else `pending` — and the download is started or moved up.
	func thumbnail(_ params: ThumbnailParams) throws -> ThumbnailResult {
		guard let image = ThumbnailDownloader.shared.thumbnail(url: params.url, mode: params.mode.thumbnailMode, feedName: params.feedName, articleTitle: params.articleTitle) else {
			return ThumbnailResult(png: nil, width: 0, height: 0, isPending: true)
		}
		let key = "\(params.mode.rawValue) \(params.url)"
		let png: String
		if let cached = Self.encodedThumbnails[key], cached.image === image {
			png = cached.png
		} else {
			guard let data = image.pngData() else {
				throw CoreServiceError(code: "failed", message: "Could not encode the thumbnail.")
			}
			png = data.base64EncodedString()
			if Self.encodedThumbnails.count > Self.maxEncodedThumbnails {
				Self.encodedThumbnails.removeAll()
			}
			Self.encodedThumbnails[key] = (image, png)
		}
		return ThumbnailResult(png: png, width: image.bitmap.width, height: image.bitmap.height, isPending: false)
	}

	/// Parses the HTML of articles whose image isn't known yet, off the main thread, then picks each one's thumbnail URL.
	func thumbnailURLs(for articles: [Article], mode: ThumbnailMode) async -> [String: String] {
		await ArticleThumbnailFinder.shared.findThumbnailURLs(for: articles)
		var urls = [String: String]()
		for article in articles {
			if let url = ArticleThumbnailFinder.shared.thumbnailURL(for: article, mode: mode) {
				urls[article.articleID] = url
			}
		}
		return urls
	}

	func observeThumbnailNotifications() {
		let center = NotificationCenter.default
		center.addMainActorObserver(self, name: .thumbnailDidBecomeAvailable) { service, notification in
			if let url = notification.userInfo?[ThumbnailDownloader.urlKey] as? String {
				service.enqueueThumbnailsChanged(urls: [url], articleIDs: [])
			}
		}
		// A failed image is skipped; the finder may pick another, so those articles' URLs change.
		center.addMainActorObserver(self, name: .articleThumbnailDownloadDidFail) { service, notification in
			let articleIDs = notification.userInfo?[ArticleThumbnailFinder.articleIDsKey] as? Set<String> ?? []
			service.enqueueThumbnailsChanged(urls: [], articleIDs: articleIDs)
		}
	}
}

// MARK: - Params and results

struct ThumbnailParams: Decodable {
	/// From an ArticleSummary's thumbnailURL.
	let url: String
	let mode: TimelineThumbnailMode
	/// For the activity log.
	let feedName: String?
	let articleTitle: String?
}

/// The Images module's ThumbnailMode, as requests spell it.
enum TimelineThumbnailMode: String, Decodable {
	case small, large

	var thumbnailMode: ThumbnailMode {
		switch self {
		case .small:
			return .small
		case .large:
			return .large
		}
	}
}

struct ThumbnailResult: Encodable {
	/// PNG, base64. Nil while pending.
	let png: String?
	let width: Int
	let height: Int
	/// Not decoded yet: a `thumbnailsChanged` event with this URL follows.
	let isPending: Bool
}

// MARK: - Private

private extension CoreService {

	/// The decoded images are cached by ThumbnailDownloader; this keeps their PNGs from being encoded again.
	static let maxEncodedThumbnails = 300
	static var encodedThumbnails = [String: (image: RSImage, png: String)]()
}
