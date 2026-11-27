//
//  Models.swift
//  CoreService
//
//  What crosses the boundary to the Windows app, as JSON. Plain values only —
//  no Account or Article objects leak out, so the C# side never has to keep
//  core objects alive. Dates are ISO 8601 strings.
//

import Foundation

// MARK: - Sidebar

public struct SidebarSnapshot: Codable, Sendable, Equatable {
	public let smartFeeds: [SmartFeedInfo]
	public let accounts: [AccountInfo]
	public let totalUnreadCount: Int
}

public enum SmartFeedKind: String, Codable, Sendable, CaseIterable {
	case today, unread, starred
}

public struct SmartFeedInfo: Codable, Sendable, Equatable {
	public let kind: SmartFeedKind
	public let name: String
	public let unreadCount: Int
}

public struct AccountInfo: Codable, Sendable, Equatable {
	public let accountID: String
	public let name: String
	public let type: String
	public let isActive: Bool
	public let unreadCount: Int
	public let folders: [FolderInfo]
	/// Feeds not in any folder.
	public let feeds: [FeedInfo]
}

public struct FolderInfo: Codable, Sendable, Equatable {
	/// Stable only for this run of the app.
	public let folderID: Int
	public let name: String
	public let unreadCount: Int
	public let feeds: [FeedInfo]
}

public struct FeedInfo: Codable, Sendable, Equatable {
	public let accountID: String
	public let feedID: String
	public let name: String
	public let url: String
	public let homePageURL: String?
	public let unreadCount: Int
}

// MARK: - Articles

/// What the timeline shows. Picking an article fetches its `ArticleDetail`.
public struct ArticleSummary: Codable, Sendable, Equatable {
	public let accountID: String
	public let articleID: String
	public let feedID: String
	public let feedName: String
	public let title: String?
	/// Plain text from the summary or body, for a preview line.
	public let summary: String?
	public let link: String?
	/// The thumbnail to show in the mode `articles.fetch` was given. Nil without a mode, or with no usable image.
	public let thumbnailURL: String?
	public let date: Date
	public let isRead: Bool
	public let isStarred: Bool
}

public struct ArticleDetail: Codable, Sendable, Equatable {
	public let accountID: String
	public let articleID: String
	public let feedID: String
	public let feedName: String
	public let feedHomePageURL: String?
	public let title: String?
	public let html: String?
	public let link: String?
	public let externalLink: String?
	public let imageURL: String?
	public let authors: [AuthorInfo]
	public let datePublished: Date?
	public let dateModified: Date?
	public let isRead: Bool
	public let isStarred: Bool
}

public struct AuthorInfo: Codable, Sendable, Equatable {
	public let name: String?
	public let url: String?
	public let avatarURL: String?
	public let emailAddress: String?
}

/// Which articles to fetch for the timeline.
public struct ArticleSelection: Codable, Sendable, Equatable {
	public enum Kind: String, Codable, Sendable {
		case today, unread, starred, feed, folder, search
	}

	public var kind: Kind
	public var accountID: String?
	public var feedID: String?
	public var folderID: Int?
	public var query: String?
	/// For a folder: only unread articles.
	public var unreadOnly: Bool?

	public init(kind: Kind, accountID: String? = nil, feedID: String? = nil, folderID: Int? = nil, query: String? = nil, unreadOnly: Bool? = nil) {
		self.kind = kind
		self.accountID = accountID
		self.feedID = feedID
		self.folderID = folderID
		self.query = query
		self.unreadOnly = unreadOnly
	}
}

public struct ArticleReference: Codable, Sendable, Hashable {
	public let accountID: String
	public let articleID: String

	public init(accountID: String, articleID: String) {
		self.accountID = accountID
		self.articleID = articleID
	}
}

// MARK: - Events

/// Pushed to the app as things change. Several changes in one main-queue turn arrive
/// as one event of each type, so a refresh doesn't flood the UI thread.
public struct CoreEvent: Codable, Sendable, Equatable {
	public enum Kind: String, Codable, Sendable {
		/// Feeds, folders, or accounts were added, removed, renamed, or moved.
		case sidebarChanged
		/// Some unread count changed. Fetch the sidebar again.
		case unreadCountsChanged
		/// Read or starred status changed for `articleIDs` (nil: unknown, refetch all).
		case statusesChanged
		/// A refresh downloaded new or updated articles.
		case articlesChanged
		/// Refresh progress: `progress` is set.
		case refreshProgress
		/// Feed icons changed for `feedIDs` (nil: any icon, such as an author avatar, may have).
		case iconsChanged
		/// Thumbnails at `urls` are ready; the articles in `articleIDs` have a new thumbnail URL (fetch them again).
		case thumbnailsChanged
	}

	public let kind: Kind
	public var articleIDs: [String]?
	public var feedIDs: [String]?
	public var urls: [String]?
	public var progress: RefreshProgress?
}

public struct RefreshProgress: Codable, Sendable, Equatable {
	public let numberOfTasks: Int
	public let numberCompleted: Int
	public let numberRemaining: Int
	public let isComplete: Bool
}
