//
//  CoreService+Methods.swift
//  CoreService
//
//  The request methods. Each is `noun.verb`, takes a JSON object of params,
//  and returns a JSON value. See Technotes/WindowsPort.md for the list.
//

import Foundation
import Synchronization
import RSCore
import Articles
import Account
import Images

extension CoreService {

	func route(method: String, request: Request) async throws -> Data {
		switch method {
		case "core.info":
			return try Self.response(CoreInfo(version: Self.version, dataFolder: AppConfig.dataFolder.path))

		case "sidebar.get":
			return try Self.response(await sidebar())

		case "articles.fetch":
			let params = try request.decode(FetchArticlesParams.self)
			return try Self.response(await fetchArticles(params.selection, limit: params.limit, sort: params.sortParameters, groupByFeed: params.groupByFeed ?? false, thumbnailMode: params.thumbnailMode?.thumbnailMode))
		case "themes.download":
			let params = try request.decode(ThemeURLParams.self)
			return try Self.response(try await downloadTheme(params))
		case "themes.inspect":
			let params = try request.decode(InstallThemeParams.self)
			return try Self.response(try inspectTheme(params))
		case "app.interpretOpenedURL":
			let params = try request.decode(OpenedURLParams.self)
			return try Self.response(interpretOpenedURL(params))
		case "refresh.schedule":
			let params = try request.decode(RefreshScheduleParams.self)
			scheduleRefresh(params)
			return try Self.response(Empty())
		case "app.prepareToQuit":
			await prepareToQuit()
			return try Self.response(Empty())

		case "feeds.setNotifications":
			let params = try request.decode(FeedNotificationsParams.self)
			try setFeedNotifications(params)
			return try Self.response(Empty())

		case "accounts.types":
			return try Self.response(accountTypes())
		case "accounts.add":
			let params = try request.decode(AddAccountParams.self)
			return try Self.response(try await addAccount(params))
		case "accounts.delete":
			let params = try request.decode(AccountIDParams.self)
			try deleteAccount(params)
			return try Self.response(Empty())
		case "accounts.setActive":
			let params = try request.decode(SetAccountActiveParams.self)
			try setAccountActive(params)
			return try Self.response(Empty())

		case "articles.sort":
			let params = try request.decode(SortArticlesParams.self)
			return try Self.response(await sortArticles(params))
		case "article.get":
			let params = try request.decode(ArticleReference.self)
			return try Self.response(try articleDetail(params))
		case "article.render":
			return try Self.response(try renderArticle(try request.decode(RenderArticleParams.self)))
		case "article.renderMessage":
			return try Self.response(renderMessage(try request.decode(RenderMessageParams.self)))
		case "article.scripts":
			return try Self.response(articleScripts())
		case "icons.feed":
			return try Self.response(try feedIcon(try request.decode(FeedIconParams.self)))
		case "icons.article":
			return try Self.response(try articleIcon(try request.decode(ArticleReference.self)))
		case "thumbnails.get":
			return try Self.response(try thumbnail(try request.decode(ThumbnailParams.self)))
		case "themes.list":
			return try Self.response(listThemes())
		case "themes.install":
			return try Self.response(try installTheme(try request.decode(InstallThemeParams.self)))
		case "themes.delete":
			try deleteTheme(try request.decode(ThemeNameParams.self))
			return try Self.response(Empty())
		case "articles.mark":
			try await markArticles(try request.decode(MarkArticlesParams.self))
			return try Self.response(Empty())

		case "feeds.subscribe":
			return try Self.response(try await subscribe(try request.decode(SubscribeParams.self)))
		case "feeds.delete":
			try await deleteFeed(try request.decode(FeedLocationParams.self))
			return try Self.response(Empty())
		case "feeds.rename":
			let params = try request.decode(RenameFeedParams.self)
			let (account, feed) = try existingFeed(accountID: params.accountID, feedID: params.feedID)
			try await account.renameFeed(feed, name: params.name)
			return try Self.response(Empty())
		case "feeds.move":
			try await moveFeed(try request.decode(MoveFeedParams.self))
			return try Self.response(Empty())

		case "folders.add":
			let params = try request.decode(AddFolderParams.self)
			let account = try existingAccount(params.accountID)
			let folder = try await account.addFolder(params.name)
			return try Self.response(folderInfo(folder, account: account))
		case "folders.rename":
			let params = try request.decode(RenameFolderParams.self)
			let (account, folder) = try existingFolder(accountID: params.accountID, folderID: params.folderID)
			try await account.renameFolder(folder, to: params.name)
			return try Self.response(Empty())
		case "folders.delete":
			let params = try request.decode(FolderLocationParams.self)
			let (account, folder) = try existingFolder(accountID: params.accountID, folderID: params.folderID)
			try await result { account.removeFolder(folder, completion: $0) }
			return try Self.response(Empty())

		case "opml.import":
			let params = try request.decode(ImportOPMLParams.self)
			let account = try existingAccount(params.accountID)
			try await result { account.importOPML(URL(filePath: params.path), completion: $0) }
			return try Self.response(Empty())
		case "opml.export":
			let params = try request.decode(AccountParams.self)
			let account = try existingAccount(params.accountID)
			return try Self.response(ExportOPMLResult(opml: Self.opmlString(account)))

		case "refresh.all":
			let errors = ErrorCollector()
			let didRefresh = await accountManager.refreshAll { error in
				errors.append(error.localizedDescription)
			}
			return try Self.response(RefreshResult(didRefresh: didRefresh, errors: errors.messages))

		default:
			throw CoreServiceError.unknownMethod(method)
		}
	}
}

// MARK: - Params and results

struct CoreInfo: Encodable {
	let version: String
	let dataFolder: String
}

struct AccountParams: Decodable {
	/// Nil means the local account.
	let accountID: String?
}

struct FetchArticlesParams: Decodable {
	let selection: ArticleSelection
	let limit: Int?
	/// small or large: fill in each article's thumbnailURL, as the timeline shows it.
	let thumbnailMode: TimelineThumbnailMode?
	/// Newest first when nil.
	let sort: SortParams?
	/// With a date sort, keeps each feed's articles together, feeds A to Z — the Mac's Group by Feed.
	let groupByFeed: Bool?

	var sortParameters: ArticleSortParameters {
		Self.sortParameters(sort)
	}

	static func sortParameters(_ sort: SortParams?) -> ArticleSortParameters {
		guard let sort else {
			return .newestFirst
		}
		return ArticleSortParameters(key: sort.key, direction: sort.ascending ? .orderedAscending : .orderedDescending)
	}
}

struct SortArticlesParams: Decodable {
	/// The timeline's rows, in any order.
	let articles: [ArticleReference]
	let sort: SortParams?
	let groupByFeed: Bool?

	var sortParameters: ArticleSortParameters {
		FetchArticlesParams.sortParameters(sort)
	}
}

/// The Mac timeline's sort: a field and a direction. Every field but date sorts by date, newest first, within it.
struct SortParams: Decodable {
	let key: ArticleSortKey
	let ascending: Bool

	private enum CodingKeys: String, CodingKey {
		case key, ascending
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let name = try container.decode(String.self, forKey: .key)
		guard let key = ArticleSortKey(rawValue: name) else {
			throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "The sort key is date, feed, title, unread, or starred.")
		}
		self.key = key
		self.ascending = try container.decode(Bool.self, forKey: .ascending)
	}
}

struct MarkArticlesParams: Decodable {
	enum Key: String, Decodable {
		case read, starred
	}
	let articles: [ArticleReference]
	let key: Key
	let flag: Bool
}

struct SubscribeParams: Decodable {
	let url: String
	let name: String?
	let accountID: String?
	/// Nil: at the top level of the account.
	let folderID: Int?
}

struct FeedLocationParams: Decodable {
	let accountID: String
	let feedID: String
	/// The folder to remove it from. Nil: the top level.
	let folderID: Int?
}

struct RenameFeedParams: Decodable {
	let accountID: String
	let feedID: String
	let name: String
}

struct MoveFeedParams: Decodable {
	let accountID: String
	let feedID: String
	let fromFolderID: Int?
	let toFolderID: Int?
}

struct AddFolderParams: Decodable {
	let accountID: String?
	let name: String
}

struct RenameFolderParams: Decodable {
	let accountID: String
	let folderID: Int
	let name: String
}

struct FolderLocationParams: Decodable {
	let accountID: String
	let folderID: Int
}

struct ImportOPMLParams: Decodable {
	let path: String
	let accountID: String?
}

struct ExportOPMLResult: Encodable {
	let opml: String
}

struct RefreshResult: Encodable {
	/// False when skipped because there's no network connection.
	let didRefresh: Bool
	let errors: [String]
}

/// Collects error messages from refresh tasks, which report them from any isolation.
final class ErrorCollector: Sendable {
	private let storage = Mutex<[String]>([])

	var messages: [String] {
		storage.withLock { $0 }
	}

	func append(_ message: String) {
		storage.withLock { $0.append(message) }
	}
}

// MARK: - Sidebar

private extension CoreService {

	func sidebar() async -> SidebarSnapshot {
		let activeAccounts = accountManager.activeAccounts

		var starredUnreadCount = 0
		for account in activeAccounts {
			starredUnreadCount += await account.fetchUnreadCountForStarredArticlesAsync()
		}
		let todayUnreadCount = await accountManager.fetchUnreadCountForTodayAsync()

		let smartFeeds = [
			SmartFeedInfo(kind: .today, name: "Today", unreadCount: todayUnreadCount),
			SmartFeedInfo(kind: .unread, name: "All Unread", unreadCount: accountManager.unreadCount),
			SmartFeedInfo(kind: .starred, name: "Starred", unreadCount: starredUnreadCount)
		]

		let accounts = accountManager.sortedAccounts.map { account in
			AccountInfo(
				accountID: account.accountID,
				name: account.nameForDisplay,
				type: String(describing: account.type),
				isActive: account.isActive,
				unreadCount: account.unreadCount,
				folders: (account.sortedFolders ?? []).map { folderInfo($0, account: account) },
				feeds: sortedFeedInfos(account.topLevelFeeds, account: account)
			)
		}

		return SidebarSnapshot(smartFeeds: smartFeeds, accounts: accounts, totalUnreadCount: accountManager.unreadCount)
	}

	func sortedFeedInfos(_ feeds: Set<Feed>, account: Account) -> [FeedInfo] {
		feeds
			.sorted { $0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending }
			.map { feedInfo($0, account: account) }
	}
}

extension CoreService {

	func feedInfo(_ feed: Feed, account: Account) -> FeedInfo {
		FeedInfo(accountID: account.accountID, feedID: feed.feedID, name: feed.nameForDisplay, url: feed.url, homePageURL: feed.homePageURL, unreadCount: feed.unreadCount, notifiesAboutNewArticles: feed.newArticleNotificationsEnabled)
	}

	func folderInfo(_ folder: Folder, account: Account) -> FolderInfo {
		FolderInfo(folderID: folder.folderID, name: folder.nameForDisplay, unreadCount: folder.unreadCount, feeds: folder.topLevelFeeds
			.sorted { $0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending }
			.map { feedInfo($0, account: account) })
	}
}

// MARK: - Articles

private extension CoreService {

	static let summaryLength = 200

	func fetchArticles(_ selection: ArticleSelection, limit: Int?, sort: ArticleSortParameters, groupByFeed: Bool, thumbnailMode: ThumbnailMode?) async throws -> [ArticleSummary] {
		let articles: Set<Article>
		switch selection.kind {
		case .today:
			articles = await accountManager.fetchArticlesAsync(.today())
		case .unread:
			articles = await accountManager.fetchArticlesAsync(.unread())
		case .starred:
			articles = await accountManager.fetchArticlesAsync(.starred())
		case .search:
			guard let query = selection.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
				throw CoreServiceError.invalidParams("A search needs a query.")
			}
			articles = await accountManager.fetchArticlesAsync(.search(query))
		case .feed:
			guard let accountID = selection.accountID, let feedID = selection.feedID else {
				throw CoreServiceError.invalidParams("A feed selection needs accountID and feedID.")
			}
			let (account, feed) = try existingFeed(accountID: accountID, feedID: feedID)
			articles = await account.fetchArticlesAsync(.feed(feed))
		case .folder:
			guard let accountID = selection.accountID, let folderID = selection.folderID else {
				throw CoreServiceError.invalidParams("A folder selection needs accountID and folderID.")
			}
			let (account, folder) = try existingFolder(accountID: accountID, folderID: folderID)
			articles = await account.fetchArticlesAsync(.folder(folder, selection.unreadOnly ?? false))
		}

		var sortedArticles = sorted(Array(articles), sort: sort, groupByFeed: groupByFeed)
		if let limit, limit >= 0, sortedArticles.count > limit {
			sortedArticles = Array(sortedArticles.prefix(limit))
		}
		var chosenThumbnailURLs = [String: String]()
		if let thumbnailMode {
			chosenThumbnailURLs = await thumbnailURLs(for: sortedArticles, mode: thumbnailMode)
		}
		return sortedArticles.map { articleSummary($0, thumbnailURL: chosenThumbnailURLs[$0.articleID]) }
	}

	/// The same rows in the order of a new sort, as the Mac re-sorts its timeline: rows that no longer match the selection stay.
	/// References to articles that are gone are left out.
	func sortArticles(_ params: SortArticlesParams) async throws -> [ArticleReference] {
		let idsByAccount = Dictionary(grouping: params.articles, by: \.accountID).mapValues { Set($0.map(\.articleID)) }
		var articles = [Article]()
		for (accountID, articleIDs) in idsByAccount {
			let account = try existingAccount(accountID)
			articles += await account.fetchArticlesAsync(.articleIDs(articleIDs))
		}
		return sorted(articles, sort: params.sortParameters, groupByFeed: params.groupByFeed ?? false).map {
			ArticleReference(accountID: $0.accountID, articleID: $0.articleID)
		}
	}

	/// Sorted by the Articles module, as the Mac timeline sorts. Group by Feed only applies to a date sort, as on the Mac.
	func sorted(_ articles: [Article], sort: ArticleSortParameters, groupByFeed: Bool) -> [Article] {
		if sort.key == .date {
			return ArticleSorter.sortedByDate(articles: articles, sortDirection: sort.direction, groupByFeed: groupByFeed, feedNameFor: sortableFeedName)
		}
		return ArticleSorter.sorted(articles: articles, parameters: sort, feedNameFor: sortableFeedName, titleFor: sortableTitle)
	}

	func sortableFeedName(_ article: Article) -> String {
		accountManager.existingAccount(accountID: article.accountID)?.existingFeed(withFeedID: article.feedID)?.nameForDisplay ?? ""
	}

	/// The text the timeline shows as the title: the title, or the start of the body for an untitled article.
	func sortableTitle(_ article: Article) -> String {
		if let title = article.title?.strippingHTML().collapsingWhitespace, !title.isEmpty {
			return title
		}
		return previewText(article) ?? ""
	}

	func previewText(_ article: Article) -> String? {
		let previewSource = article.summary ?? article.contentHTML ?? article.contentText
		guard let preview = previewSource.map({ $0.strippingHTML(maxCharacters: Self.summaryLength).collapsingWhitespace }), !preview.isEmpty else {
			return nil
		}
		return preview
	}

	func articleSummary(_ article: Article, thumbnailURL: String?) -> ArticleSummary {
		let feed = accountManager.existingAccount(accountID: article.accountID)?.existingFeed(withFeedID: article.feedID)
		return ArticleSummary(
			accountID: article.accountID,
			articleID: article.articleID,
			feedID: article.feedID,
			feedName: feed?.nameForDisplay ?? "",
			title: article.title,
			summary: previewText(article),
			link: article.preferredLink,
			thumbnailURL: thumbnailURL,
			date: article.logicalDatePublished,
			isRead: article.status.read,
			isStarred: article.status.starred
		)
	}

	func articleDetail(_ reference: ArticleReference) throws -> ArticleDetail {
		guard let article = accountManager.fetchArticle(accountID: reference.accountID, articleID: reference.articleID) else {
			throw CoreServiceError.notFound("Article \(reference.articleID)")
		}
		let feed = accountManager.existingAccount(accountID: article.accountID)?.existingFeed(withFeedID: article.feedID)
		let authors = (article.authors ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }.map {
			AuthorInfo(name: $0.name, url: $0.url, avatarURL: $0.avatarURL, emailAddress: $0.emailAddress)
		}

		return ArticleDetail(
			accountID: article.accountID,
			articleID: article.articleID,
			feedID: article.feedID,
			feedName: feed?.nameForDisplay ?? "",
			feedHomePageURL: feed?.homePageURL,
			title: article.title,
			html: article.contentHTML ?? article.contentText.map(\.convertingPlainTextToHTML) ?? article.summary,
			link: article.link,
			externalLink: article.externalLink,
			imageURL: article.imageLink,
			authors: authors,
			datePublished: article.datePublished,
			dateModified: article.dateModified,
			isRead: article.status.read,
			isStarred: article.status.starred
		)
	}

	func markArticles(_ params: MarkArticlesParams) async throws {
		let key: ArticleStatus.Key = params.key == .read ? .read : .starred
		let articleIDsByAccountID = Dictionary(grouping: params.articles, by: \.accountID).mapValues { Set($0.map(\.articleID)) }
		for (accountID, articleIDs) in articleIDsByAccountID {
			let account = try existingAccount(accountID)
			try await account.markArticles(articleIDs: articleIDs, statusKey: key, flag: params.flag)
		}
	}
}

// MARK: - Feeds and folders

private extension CoreService {

	func subscribe(_ params: SubscribeParams) async throws -> FeedInfo {
		let account = try existingAccount(params.accountID)
		let container: Container
		if let folderID = params.folderID {
			container = try existingFolder(account: account, folderID: folderID)
		} else {
			container = account
		}
		let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines)
		let feed: Feed = try await result {
			account.createFeed(url: params.url, name: name?.isEmpty == false ? name : nil, container: container, validateFeed: true, completion: $0)
		}
		return feedInfo(feed, account: account)
	}

	func deleteFeed(_ params: FeedLocationParams) async throws {
		let (account, feed) = try existingFeed(accountID: params.accountID, feedID: params.feedID)
		let container: Container = try params.folderID.map { try existingFolder(account: account, folderID: $0) } ?? account
		try await result { account.removeFeed(feed, from: container, completion: $0) }
	}

	func moveFeed(_ params: MoveFeedParams) async throws {
		let (account, feed) = try existingFeed(accountID: params.accountID, feedID: params.feedID)
		let source: Container = try params.fromFolderID.map { try existingFolder(account: account, folderID: $0) } ?? account
		let destination: Container = try params.toFolderID.map { try existingFolder(account: account, folderID: $0) } ?? account
		try await result { account.moveFeed(feed, from: source, to: destination, completion: $0) }
	}

	/// Awaits an API that reports through a completion handler.
	func result<Value: Sendable>(_ body: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
		try await withCheckedThrowingContinuation { continuation in
			body { continuation.resume(with: $0) }
		}
	}
}

// MARK: - Lookup

extension CoreService {

	/// Nil means the local account.
	func existingAccount(_ accountID: String?) throws -> Account {
		guard let accountID else {
			return accountManager.defaultAccount
		}
		guard let account = accountManager.existingAccount(accountID: accountID) else {
			throw CoreServiceError.notFound("Account \(accountID)")
		}
		return account
	}

	func existingFeed(accountID: String, feedID: String) throws -> (Account, Feed) {
		let account = try existingAccount(accountID)
		guard let feed = account.existingFeed(withFeedID: feedID) else {
			throw CoreServiceError.notFound("Feed \(feedID)")
		}
		return (account, feed)
	}

	func existingFolder(accountID: String, folderID: Int) throws -> (Account, Folder) {
		let account = try existingAccount(accountID)
		return (account, try existingFolder(account: account, folderID: folderID))
	}

	func existingFolder(account: Account, folderID: Int) throws -> Folder {
		guard let folder = account.folders?.first(where: { $0.folderID == folderID }) else {
			throw CoreServiceError.notFound("Folder \(folderID)")
		}
		return folder
	}
}

// MARK: - OPML

extension CoreService {

	/// The same document the Mac and iOS apps export (Shared/Exporters/OPMLExporter.swift).
	static func opmlString(_ account: Account) -> String {
		let escapedTitle = account.nameForDisplay.escapingSpecialXMLCharacters
		return """
			<?xml version="1.0" encoding="UTF-8"?>
			<!-- OPML generated by NetNewsWire -->
			<opml version="1.1">
				<head>
					<title>\(escapedTitle)</title>
				</head>
			<body>

			""" + account.OPMLString(indentLevel: 0) + """
				</body>
			</opml>
			"""
	}
}
