//
//  IconImageCache.swift
//  NetNewsWire-iOS
//
//  Created by Brent Simmons on 5/2/21.
//  Copyright © 2021 Ranchero Software. All rights reserved.
//

import Foundation
import Account
import Articles
import RSCore
import Images

extension Notification.Name {
	/// Posted when the icon `iconImage(for:)` returns for a feed may have changed. userInfo key: `UserInfoKey.feed`.
	static let feedIconImageDidChange = Notification.Name("FeedIconImageDidChange")
	/// Posted when an author’s avatar loads or changes. userInfo key: `UserInfoKey.url` (the avatar URL).
	static let authorAvatarImageDidChange = Notification.Name("AuthorAvatarImageDidChange")
}

/// The icons the UI shows for feeds, articles, and sidebar items. The UI watches its two notifications, not the downloaders’.
@MainActor final class IconImageCache {

	static var shared = IconImageCache()

	private var smartFeedIconImageCache = [SidebarItemIdentifier: IconImage]()
	private var smallIconImageCache = [SidebarItemIdentifier: IconImage]()

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleFeedIconDidChange(_:)), name: .feedIconDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleHomePageIconDidChange(_:)), name: .homePageIconDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleFaviconDidChange(_:)), name: .faviconDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleAvatarDidChange(_:)), name: .avatarDidChange, object: nil)
	}

	@objc func handleLowMemory(_ notification: Notification) {
		emptyCache()
	}

	@objc func handleFeedIconDidChange(_ notification: Notification) {
		postFeedIconImageDidChange(notification.userInfo?[FeedIconDownloader.feedsKey] as? Set<Feed>)
	}

	@objc func handleHomePageIconDidChange(_ notification: Notification) {
		postFeedIconImageDidChange(notification.userInfo?[HomePageIconDownloader.feedsKey] as? Set<Feed>)
	}

	@objc func handleFaviconDidChange(_ notification: Notification) {
		postFeedIconImageDidChange(notification.userInfo?[FaviconDownloader.feedsKey] as? Set<Feed>)
	}

	@objc func handleAvatarDidChange(_ notification: Notification) {
		guard let avatarURL = notification.userInfo?[AuthorAvatarDownloader.avatarURLKey] as? String else {
			return
		}
		NotificationCenter.default.post(name: .authorAvatarImageDidChange, object: self, userInfo: [UserInfoKey.url: avatarURL])
	}

	func imageFor(_ feedID: SidebarItemIdentifier) -> IconImage? {
		if let smartFeed = SmartFeedsController.shared.find(by: feedID) {
			return imageForFeed(smartFeed)
		}
		if let feed = AccountManager.shared.existingFeed(with: feedID) {
			return imageForFeed(feed)
		}
		return nil
	}

	func imageForFeed(_ sidebarItem: SidebarItem) -> IconImage? {
		if let feed = sidebarItem as? Feed {
			return iconImage(for: feed)
		}
		guard let sidebarItemID = sidebarItem.sidebarItemID else {
			return nil
		}
		if let smartFeed = sidebarItem as? PseudoFeed {
			return imageForSmartFeed(smartFeed, sidebarItemID)
		}
		if let smallIconProvider = sidebarItem as? SmallIconProvider {
			return imageForSmallIconProvider(smallIconProvider, sidebarItemID)
		}

		return nil
	}

	func prefetchImagesForArticles(_ articles: ArticleArray) {

		var feedsSeen = Set<SidebarItemIdentifier>()
		var authorsSeen = Set<String>()

		for article in articles {
			if let authors = article.authors {
				for author in authors {
					if let avatarURL = author.avatarURL, !authorsSeen.contains(avatarURL) {
						authorsSeen.insert(avatarURL)
						_ = AuthorAvatarDownloader.shared.avatar(for: author)
					}
				}
			}

			if let feed = article.feed, let feedID = feed.sidebarItemID, !feedsSeen.contains(feedID) {
				feedsSeen.insert(feedID)
				_ = FeedIconResolver.shared.feedIcon(for: feed)
			}
		}
	}

	func prefetchImagesForFeeds(_ feeds: [Feed]) {
		for feed in feeds {
			_ = FeedIconResolver.shared.feedIcon(for: feed)
		}
	}

	/// Precedence: author avatar, then the feed’s icon.
	func imageForArticle(_ article: Article) -> IconImage? {
		if let iconImage = imageForAuthors(article.authors) {
			return iconImage
		}
		guard let feed = article.feed else {
			return nil
		}
		return iconImage(for: feed)
	}

	/// Grayscale when `AppDefaults.grayscaleIcons` is on.
	func iconImage(for feed: Feed) -> IconImage {
		displayedIconImage(colorIconImage(for: feed))
	}

	/// Grayscale when `AppDefaults.grayscaleIcons` is on.
	func displayedIconImage(_ iconImage: IconImage) -> IconImage {
		AppDefaults.grayscaleIcons ? iconImage.grayscaleIconImage : iconImage
	}

	func emptyCache() {
		smartFeedIconImageCache.removeAll()
		smallIconImageCache.removeAll()
		FeedIconResolver.shared.emptyCache()
	}
}

private extension IconImageCache {

	/// The feed’s icon, as FeedIconResolver picks it (shared with the Windows app).
	func colorIconImage(for feed: Feed) -> IconImage {
		FeedIconResolver.shared.colorIconImage(for: feed, brandedIcon: IconImage.nnwFeedIcon)
	}

	func postFeedIconImageDidChange(_ feeds: Set<Feed>?) {
		guard let feeds else {
			return
		}
		for feed in feeds {
			NotificationCenter.default.post(name: .feedIconImageDidChange, object: self, userInfo: [UserInfoKey.feed: feed])
		}
	}

	func imageForSmartFeed(_ smartFeed: PseudoFeed, _ feedID: SidebarItemIdentifier) -> IconImage? {
		if let iconImage = smartFeedIconImageCache[feedID] {
			return displayedIconImage(iconImage)
		}
		if let iconImage = smartFeed.smallIcon {
			smartFeedIconImageCache[feedID] = iconImage
			return displayedIconImage(iconImage)
		}
		return nil
	}

	func imageForSmallIconProvider(_ provider: SmallIconProvider, _ feedID: SidebarItemIdentifier) -> IconImage? {
		if let iconImage = smallIconImageCache[feedID] {
			return displayedIconImage(iconImage)
		}
		if let iconImage = provider.smallIcon {
			smallIconImageCache[feedID] = iconImage
			return displayedIconImage(iconImage)
		}
		return nil
	}

	func imageForAuthors(_ authors: Set<Author>?) -> IconImage? {
		FeedIconResolver.shared.avatar(for: authors).map(displayedIconImage)
	}

	func imageForAuthor(_ author: Author) -> IconImage? {
		FeedIconResolver.shared.avatar(for: author).map(displayedIconImage)
	}
}
