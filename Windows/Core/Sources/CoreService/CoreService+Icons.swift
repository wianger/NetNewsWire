//
//  CoreService+Icons.swift
//  CoreService
//
//  Feed icons and author avatars, chosen by FeedIconResolver (Images) as on the Mac and
//  decoded by WIC. They cross to the app as PNG, which WinUI's BitmapImage and WebView2 both take.
//

import Foundation
import RSCore
import Articles
import Account
import Images

extension CoreService {

	/// Images needs two pictures from the app before it shows any icon. Call once at start.
	func setUpIcons() {
		guard FaviconGenerator.templateImage == nil else {
			return
		}
		FaviconGenerator.templateImage = Self.resourceImage("faviconTemplate")
		observeIconNotifications()
	}

	func feedIcon(_ params: FeedIconParams) throws -> IconResult {
		let (_, feed) = try existingFeed(accountID: params.accountID, feedID: params.feedID)
		return try iconResult(FeedIconResolver.shared.colorIconImage(for: feed, brandedIcon: Self.brandedFeedIcon))
	}

	/// The author's avatar, else the feed's icon — the image at the top of the article page.
	func articleIcon(_ params: ArticleReference) throws -> IconResult {
		guard let article = accountManager.fetchArticle(accountID: params.accountID, articleID: params.articleID) else {
			throw CoreServiceError.notFound("Article \(params.articleID)")
		}
		if let avatar = FeedIconResolver.shared.avatar(for: article.authors) {
			return try iconResult(avatar)
		}
		guard let feed = article.feed else {
			throw CoreServiceError.notFound("Feed for article \(params.articleID)")
		}
		return try iconResult(FeedIconResolver.shared.colorIconImage(for: feed, brandedIcon: Self.brandedFeedIcon))
	}
}

// MARK: - Params and results

struct FeedIconParams: Decodable {
	let accountID: String
	let feedID: String
}

struct IconResult: Encodable {
	/// PNG, base64.
	let png: String
	let width: Int
	let height: Int
	/// Mostly dark or mostly bright pixels: the app may draw a backplate so the icon shows on its background.
	let isDark: Bool
	let isBright: Bool
	/// A generated placeholder or a template-style icon whose own background is suppressed.
	let isBackgroundSuppressed: Bool
}

// MARK: - Private

private extension CoreService {

	static let brandedFeedIcon: IconImage = {
		guard let image = resourceImage("nnwFeedIcon") else {
			preconditionFailure("CoreService is missing its resource nnwFeedIcon.png")
		}
		return IconImage(image)
	}()

	static func resourceImage(_ name: String) -> RSImage? {
		guard let url = Bundle.module.url(forResource: name, withExtension: "png"), let data = try? Data(contentsOf: url) else {
			return nil
		}
		return RSImage(data: data)
	}

	/// PNG-encoding the same icon again for every row would be wasted work.
	static var encodedIcons = [ObjectIdentifier: (iconImage: IconImage, png: String)]()

	func iconResult(_ iconImage: IconImage) throws -> IconResult {
		let key = ObjectIdentifier(iconImage)
		let png: String
		if let cached = Self.encodedIcons[key], cached.iconImage === iconImage {
			png = cached.png
		} else {
			guard let data = iconImage.image.pngData() else {
				throw CoreServiceError(code: "failed", message: "Could not encode the icon.")
			}
			png = data.base64EncodedString()
			if Self.encodedIcons.count > 2000 {
				Self.encodedIcons.removeAll()
			}
			Self.encodedIcons[key] = (iconImage, png)
		}
		return IconResult(png: png, width: iconImage.image.bitmap.width, height: iconImage.image.bitmap.height, isDark: iconImage.isDark, isBright: iconImage.isBright, isBackgroundSuppressed: iconImage.isBackgroundSuppressed)
	}

	func observeIconNotifications() {
		let center = NotificationCenter.default
		let feedIconNotifications: [(Notification.Name, String)] = [
			(.feedIconDidChange, FeedIconDownloader.feedsKey),
			(.homePageIconDidChange, HomePageIconDownloader.feedsKey),
			(.faviconDidChange, FaviconDownloader.feedsKey)
		]
		for (name, feedsKey) in feedIconNotifications {
			center.addMainActorObserver(self, name: name) { service, notification in
				let feeds = notification.userInfo?[feedsKey] as? Set<Feed>
				service.enqueueIconsChanged(feeds.map { Set($0.map(\.feedID)) })
			}
		}
		// An avatar can be on any article, so the app refetches the icons it shows.
		center.addMainActorObserver(self, name: .avatarDidChange) { service, _ in
			service.enqueueIconsChanged(nil)
		}
	}
}
