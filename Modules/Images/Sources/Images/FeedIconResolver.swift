//
//  FeedIconResolver.swift
//  Images
//
//  Which icon a feed or an author shows. Moved from the app’s IconImageCache (Shared/),
//  which now uses it, so every app — Mac, iOS, Windows — picks icons the same way.
//

import Foundation
import Articles
import Account

@MainActor public final class FeedIconResolver {

	public static let shared = FeedIconResolver()

	private var lastFoundFeedIconImages = [SidebarItemIdentifier: IconImage]()
	private var authorIconImageCache = [Author: IconImage]()

	public init() {}

	/// Precedence: feed icon, home page icon, favicon, generated favicon.
	///
	/// While a source is loading, or after the downloaders empty their caches, the icon found last is shown,
	/// so an icon doesn’t flash. Without one, the generated favicon is shown.
	/// NetNewsWire’s own feeds show `brandedIcon`.
	/// <https://github.com/Ranchero-Software/NetNewsWire/issues/5376>
	public func colorIconImage(for feed: Feed, brandedIcon: @autoclosure () -> IconImage) -> IconImage {
		if Self.isNetNewsWireBrandedFeed(feed) {
			return brandedIcon()
		}
		let feedID = feed.sidebarItemID
		if let iconImage = feedIcon(for: feed).iconImage {
			if let feedID {
				lastFoundFeedIconImages[feedID] = iconImage
			}
			return iconImage
		}
		if let feedID, let iconImage = lastFoundFeedIconImages[feedID] {
			return iconImage
		}
		return FaviconGenerator.shared.favicon(feed)
	}

	/// Precedence: feed icon, home page icon, favicon.
	/// Stops at the first source that has an icon or is still loading, so later sources aren’t looked up.
	public func feedIcon(for feed: Feed) -> IconLookup {
		let feedIcon = FeedIconDownloader.shared.feedIcon(for: feed)
		guard case .unavailable = feedIcon else {
			return feedIcon
		}
		let homePageIcon = HomePageIconDownloader.shared.homePageIcon(for: feed)
		guard case .unavailable = homePageIcon else {
			return homePageIcon
		}
		return FaviconDownloader.shared.favicon(for: feed)
	}

	/// The avatar for a single author. Nil for none or several.
	public func avatar(for authors: Set<Author>?) -> IconImage? {
		guard let authors, authors.count == 1, let author = authors.first else {
			return nil
		}
		return avatar(for: author)
	}

	/// The author’s avatar, or the one found last while it reloads.
	public func avatar(for author: Author) -> IconImage? {
		if let iconImage = AuthorAvatarDownloader.shared.avatar(for: author).iconImage {
			authorIconImageCache[author] = iconImage
			return iconImage
		}
		return authorIconImageCache[author]
	}

	public func emptyCache() {
		lastFoundFeedIconImages.removeAll()
		authorIconImageCache.removeAll()
	}

	public static func isNetNewsWireBrandedFeed(_ feed: Feed) -> Bool {
		if let homePageURLString = feed.homePageURL, let homePageURL = URL(string: homePageURLString), let host = homePageURL.host {
			if host == "nnw.ranchero.com" || host == "netnewswire.blog" || host.hasSuffix("netnewswire.com") {
				return true
			}
		}
		return feed.url.hasPrefix("https://ranchero.com/downloads/netnewswire")
	}
}
