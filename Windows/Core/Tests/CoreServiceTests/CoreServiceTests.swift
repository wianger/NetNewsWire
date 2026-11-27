//
//  CoreServiceTests.swift
//  CoreServiceTests
//
//  Drives the facade the way the Windows app does: method names and JSON in,
//  JSON out. Uses the local account in a per-process temporary data folder
//  (see AppConfig.unitTestFolder), and no network.
//

import Foundation
import Testing
import RSCore
import RSParser
import RSWeb
import Secrets
@testable import Account
@testable import CoreService

@MainActor @Suite(.serialized) struct CoreServiceTests {

	// MARK: - Protocol

	@Test func coreInfoReportsVersionAndTestDataFolder() async throws {
		let info = try await call("core.info", as: CoreInfoResult.self)
		#expect(info.version == CoreService.version)
		#expect(info.dataFolder.contains("NetNewsWireTests-"), "unit tests must never use the real data folder")
	}

	@Test func unknownMethodIsAnError() async throws {
		let error = try await callExpectingError("no.such.method")
		#expect(error.code == "unknownMethod")
	}

	@Test func malformedParamsAreAnError() async throws {
		let error = try await callExpectingError("articles.fetch", params: #"{"selection": 42}"#)
		#expect(error.code == "invalidParams")

		let missing = try await callExpectingError("articles.fetch", params: #"{"selection": {"kind": "feed"}}"#)
		#expect(missing.code == "invalidParams")
	}

	@Test func missingThingsAreNotFound() async throws {
		let feedError = try await callExpectingError("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "https://example.invalid/none"}}"#)
		#expect(feedError.code == "notFound")
		let accountError = try await callExpectingError("opml.export", params: #"{"accountID": "nope"}"#)
		#expect(accountError.code == "notFound")
	}

	// MARK: - Sidebar, folders, feeds

	@Test func sidebarHasSmartFeedsAndTheLocalAccount() async throws {
		let sidebar = try await call("sidebar.get", as: SidebarSnapshot.self)
		#expect(sidebar.smartFeeds.map(\.kind) == [.today, .unread, .starred])
		let localAccount = try #require(sidebar.accounts.first { $0.accountID == "OnMyMac" })
		#expect(localAccount.isActive)
	}

	@Test func foldersCanBeAddedRenamedAndDeleted() async throws {
		let folder = try await call("folders.add", params: #"{"name": "Tech Folder"}"#, as: FolderInfo.self)
		#expect(folder.name == "Tech Folder")
		#expect(try await localAccountInfo().folders.contains { $0.folderID == folder.folderID })

		_ = try await call("folders.rename", params: #"{"accountID": "OnMyMac", "folderID": \#(folder.folderID), "name": "Renamed"}"#, as: EmptyResult.self)
		#expect(try await localAccountInfo().folders.first { $0.folderID == folder.folderID }?.name == "Renamed")

		_ = try await call("folders.delete", params: #"{"accountID": "OnMyMac", "folderID": \#(folder.folderID)}"#, as: EmptyResult.self)
		#expect(try await !localAccountInfo().folders.contains { $0.folderID == folder.folderID })
	}

	@Test func opmlImportAddsFoldersAndFeedsAndExportRoundTrips() async throws {
		let opml = """
			<?xml version="1.0" encoding="UTF-8"?>
			<opml version="1.1"><head><title>Test</title></head><body>
			<outline text="Imported Folder">
				<outline text="First" type="rss" xmlUrl="https://first.example.invalid/feed.xml" htmlUrl="https://first.example.invalid/"/>
			</outline>
			<outline text="Second" type="rss" xmlUrl="https://second.example.invalid/feed.xml"/>
			</body></opml>
			"""
		let fileURL = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).opml")
		try Data(opml.utf8).write(to: fileURL)
		defer {
			try? FileManager.default.removeItem(at: fileURL)
		}

		_ = try await call("opml.import", params: jsonObject(["path": fileURL.path]), as: EmptyResult.self)

		let account = try await localAccountInfo()
		let folder = try #require(account.folders.first { $0.name == "Imported Folder" })
		#expect(folder.feeds.map(\.url) == ["https://first.example.invalid/feed.xml"])
		// The home page comes from the feed itself on refresh, not from the OPML's htmlUrl.
		#expect(account.feeds.contains { $0.url == "https://second.example.invalid/feed.xml" })

		let exported = try await call("opml.export", as: ExportedOPML.self)
		#expect(exported.opml.contains(#"xmlUrl="https://first.example.invalid/feed.xml""#))
		#expect(exported.opml.contains("Imported Folder"))

		// Clean up so other tests see their own feeds only.
		let firstFeed = try #require(folder.feeds.first)
		_ = try await call("feeds.delete", params: #"{"accountID": "OnMyMac", "feedID": "\#(firstFeed.feedID)", "folderID": \#(folder.folderID)}"#, as: EmptyResult.self)
		_ = try await call("folders.delete", params: #"{"accountID": "OnMyMac", "folderID": \#(folder.folderID)}"#, as: EmptyResult.self)
		let secondFeed = try #require(account.feeds.first { $0.url == "https://second.example.invalid/feed.xml" })
		_ = try await call("feeds.delete", params: #"{"accountID": "OnMyMac", "feedID": "\#(secondFeed.feedID)"}"#, as: EmptyResult.self)
		#expect(try await !localAccountInfo().feeds.contains { $0.feedID == secondFeed.feedID })
	}

	@Test func feedsCanBeRenamedAndMovedIntoAFolder() async throws {
		let feed = try await makeFeed(url: "https://move.example.invalid/feed.xml", items: [])
		let folder = try await call("folders.add", params: #"{"name": "Destination"}"#, as: FolderInfo.self)

		_ = try await call("feeds.rename", params: #"{"accountID": "OnMyMac", "feedID": "\#(feed.feedID)", "name": "My Name"}"#, as: EmptyResult.self)
		_ = try await call("feeds.move", params: #"{"accountID": "OnMyMac", "feedID": "\#(feed.feedID)", "toFolderID": \#(folder.folderID)}"#, as: EmptyResult.self)

		let account = try await localAccountInfo()
		#expect(!account.feeds.contains { $0.feedID == feed.feedID })
		let movedFeed = try #require(account.folders.first { $0.folderID == folder.folderID }?.feeds.first)
		#expect(movedFeed.feedID == feed.feedID)
		#expect(movedFeed.name == "My Name")

		_ = try await call("folders.delete", params: #"{"accountID": "OnMyMac", "folderID": \#(folder.folderID)}"#, as: EmptyResult.self)
	}

	// MARK: - Accounts

	@Test func accountTypesLeaveOutDeveloperRestrictedServices() async throws {
		let types = try await call("accounts.types", as: [AccountTypeResult].self).map(\.type)
		#expect(types.contains("freshRSS") && types.contains("miniflux") && types.contains("newsBlur") && types.contains("bazQux") && types.contains("theOldReader"))
		#expect(!types.contains("feedbin") && !types.contains("feedly") && !types.contains("inoreader"))
	}

	@Test func freshRSSAccountIsValidatedAddedAndDeleted() async throws {
		TestingURLProtocol.setResponse(.init(statusCode: 200, data: Data("SID=sid\nLSID=lsid\nAuth=token123\n".utf8)), forURLContaining: "fresh.example.invalid/api/greader.php/accounts/ClientLogin")
		TestingURLProtocol.setResponse(.init(statusCode: 401, data: Data("Error=BadAuthentication".utf8)), forURLContaining: "bad.example.invalid/api/greader.php/accounts/ClientLogin")

		let missing = try await callExpectingError("accounts.add", params: #"{"type": "freshRSS", "username": "tester", "apiURL": "https://fresh.example.invalid/api/greader.php"}"#)
		#expect(missing.code == "invalidParams")
		let restricted = try await callExpectingError("accounts.add", params: #"{"type": "feedbin", "username": "tester", "password": "secret"}"#)
		#expect(restricted.code == "invalidParams")
		let rejected = try await callExpectingError("accounts.add", params: #"{"type": "freshRSS", "username": "tester", "password": "wrong", "apiURL": "https://bad.example.invalid/api/greader.php"}"#)
		#expect(rejected.code == "failed")

		let params = #"{"type": "freshRSS", "username": "tester", "password": "secret", "apiURL": "https://fresh.example.invalid/api/greader.php"}"#
		let added = try await call("accounts.add", params: params, as: AddedAccountResult.self)
		let sidebar = try await call("sidebar.get", as: SidebarSnapshot.self)
		#expect(sidebar.accounts.contains { $0.accountID == added.accountID && $0.type == "freshRSS" })

		let account = try #require(AccountManager.shared.existingAccount(accountID: added.accountID))
		#expect(account.endpointURL?.absoluteString == "https://fresh.example.invalid/api/greader.php")
		#expect(try account.retrieveCredentials(type: .readerAPIKey)?.secret == "token123")
		#expect(try account.retrieveCredentials(type: .readerBasic)?.secret == "secret")

		let duplicate = try await callExpectingError("accounts.add", params: params)
		#expect(duplicate.code == "duplicate")

		_ = try await call("accounts.setActive", params: #"{"accountID": "\#(added.accountID)", "isActive": false}"#, as: EmptyResult.self)
		#expect(!account.isActive)

		_ = try await call("accounts.delete", params: #"{"accountID": "\#(added.accountID)"}"#, as: EmptyResult.self)
		#expect(AccountManager.shared.existingAccount(accountID: added.accountID) == nil)
		#expect(try account.retrieveCredentials(type: .readerAPIKey) == nil)

		let local = try await callExpectingError("accounts.delete", params: #"{"accountID": "OnMyMac"}"#)
		#expect(local.code == "invalidParams")
	}

	// MARK: - Timers

	@Test func refreshSchedulerRunsAtItsIntervalAndStopsWhenManual() async throws {
		let counter = Counter()
		let scheduler = RefreshScheduler(checkInterval: 0.05) {
			counter.count += 1
		}
		scheduler.interval = 0.2
		try await Task.sleep(for: .seconds(0.75))
		#expect((2...4).contains(counter.count), "runs every 0.2 seconds: \(counter.count)")

		scheduler.interval = nil // Manually
		let stoppedAt = counter.count
		try await Task.sleep(for: .seconds(0.5))
		#expect(counter.count == stoppedAt)

		scheduler.fireNow()
		#expect(counter.count == stoppedAt + 1, "a refresh now, as at launch")
		scheduler.stop()
	}

	@Test func statusSyncBacksOffWhenIdleAndReturnsWhenAStatusIsQueued() async throws {
		let syncs = Counter()
		let scheduler = StatusSyncScheduler {
			syncs.count += 1
			return false // Nothing to send.
		}
		#expect(StatusSyncScheduler.normalInterval == 120 && StatusSyncScheduler.idleBackoffInterval == 1800, "the Mac's intervals")

		scheduler.start()
		#expect(!scheduler.isIdle)
		// Nothing to send: after a sync, it backs off.
		await scheduler.syncNowForTesting()
		#expect(syncs.count == 1 && scheduler.isIdle)
		// A status change queued, as marking an article read posts: back to the normal interval.
		NotificationCenter.default.post(name: .AccountDidQueueArticleStatuses, object: nil)
		#expect(!scheduler.isIdle)
		scheduler.stop()
	}

	// MARK: - Opened URLs

	@Test func openedURLsAreInterpretedAsOnTheMac() async throws {
		func action(_ url: String) async throws -> OpenedURLActionResult {
			try await call("app.interpretOpenedURL", params: try jsonObject(["url": url]), as: OpenedURLActionResult.self)
		}
		#expect(try await action("feed:https://example.com/feed.xml") == OpenedURLActionResult(kind: "addFeed", url: "https://example.com/feed.xml"))
		#expect(try await action("feed://example.com/feed.xml") == OpenedURLActionResult(kind: "addFeed", url: "http://example.com/feed.xml"))
		#expect(try await action("feeds://example.com/feed.xml") == OpenedURLActionResult(kind: "addFeed", url: "https://example.com/feed.xml"))
		#expect(try await action("x-netnewswire-feed:https://example.com/feed.xml") == OpenedURLActionResult(kind: "addFeed", url: "https://example.com/feed.xml"))
		#expect(try await action("https://example.com/feed.xml") == OpenedURLActionResult(kind: "addFeed", url: "https://example.com/feed.xml"))
		#expect(try await action("netnewswire://theme/add?url=https://example.com/Sepia.nnwtheme.zip") == OpenedURLActionResult(kind: "installTheme", url: "https://example.com/Sepia.nnwtheme.zip"))
		#expect(try await action("netnewswire://auth/feedly?code=abc").kind == "ignore")
		#expect(try await action("not a url").kind == "ignore")
	}

	// MARK: - Articles

	@Test func articlesAreFetchedNewestFirstAndMarked() async throws {
		let feed = try await makeFeed(url: "https://articles.example.invalid/feed.xml", items: [
			("older", "Older post", Self.rfc822Date(hoursAgo: 2)),
			("newer", "Newer post", Self.rfc822Date(hoursAgo: 1))
		])
		defer {
			removeFeed(feed)
		}

		let selection = #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}}"#
		let articles = try await call("articles.fetch", params: selection, as: [ArticleSummary].self)
		#expect(articles.map(\.title) == ["Newer post", "Older post"])
		#expect(articles.allSatisfy { !$0.isRead && !$0.isStarred })
		#expect(articles.first?.summary == "Body of newer")
		#expect(articles.first?.link == "https://articles.example.invalid/newer")
		#expect(articles.first?.feedName == "Articles Feed")

		let limited = try await call("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}, "limit": 1}"#, as: [ArticleSummary].self)
		#expect(limited.map(\.title) == ["Newer post"])

		let newer = try #require(articles.first)
		let reference = #"{"accountID": "\#(newer.accountID)", "articleID": "\#(newer.articleID)"}"#
		_ = try await call("articles.mark", params: #"{"articles": [\#(reference)], "key": "read", "flag": true}"#, as: EmptyResult.self)
		_ = try await call("articles.mark", params: #"{"articles": [\#(reference)], "key": "starred", "flag": true}"#, as: EmptyResult.self)

		let detail = try await call("article.get", params: reference, as: ArticleDetail.self)
		#expect(detail.isRead && detail.isStarred)
		#expect(detail.html == "<p>Body of newer</p>")
		#expect(detail.title == "Newer post")

		let starred = try await call("articles.fetch", params: #"{"selection": {"kind": "starred"}}"#, as: [ArticleSummary].self)
		#expect(starred.contains { $0.articleID == newer.articleID })
		let unread = try await call("articles.fetch", params: #"{"selection": {"kind": "unread"}}"#, as: [ArticleSummary].self)
		#expect(!unread.contains { $0.articleID == newer.articleID })
		#expect(unread.contains { $0.title == "Older post" })

		let found = try await call("articles.fetch", params: #"{"selection": {"kind": "search", "query": "Older"}}"#, as: [ArticleSummary].self)
		#expect(found.contains { $0.title == "Older post" })
	}

	@Test func articlesAreSortedAndGroupedAsOnTheMac() async throws {
		let zebra = try await makeFeed(url: "https://zebra.example.invalid/feed.xml", items: [
			("z-old", "banana", Self.rfc822Date(hoursAgo: 3)),
			("z-new", "Apple", Self.rfc822Date(hoursAgo: 1))
		])
		let aardvark = try await makeFeed(url: "https://aardvark.example.invalid/feed.xml", items: [
			("a-mid", "cherry", Self.rfc822Date(hoursAgo: 2))
		])
		defer {
			removeFeed(zebra)
			removeFeed(aardvark)
		}
		zebra.editedName = "Zebra"
		aardvark.editedName = "Aardvark"

		func titles(_ extra: String) async throws -> [String] {
			let params = #"{"selection": {"kind": "unread"}\#(extra)}"#
			let ours = ["Apple", "banana", "cherry"]
			return try await call("articles.fetch", params: params, as: [ArticleSummary].self).compactMap(\.title).filter { ours.contains($0) }
		}

		#expect(try await titles("") == ["Apple", "cherry", "banana"])
		#expect(try await titles(#", "sort": {"key": "date", "ascending": true}"#) == ["banana", "cherry", "Apple"])
		#expect(try await titles(#", "sort": {"key": "title", "ascending": true}"#) == ["Apple", "banana", "cherry"])
		#expect(try await titles(#", "sort": {"key": "feed", "ascending": true}"#) == ["cherry", "Apple", "banana"])
		// Group by Feed: feeds A to Z, each newest first, as on the Mac.
		#expect(try await titles(#", "groupByFeed": true"#) == ["cherry", "Apple", "banana"])
		// Group by Feed applies only to a date sort.
		#expect(try await titles(#", "sort": {"key": "title", "ascending": false}, "groupByFeed": true"#) == ["cherry", "banana", "Apple"])

		// Re-sorting the rows already shown, as the Mac does when the sort changes.
		let shown = try await call("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(zebra.feedID)"}}"#, as: [ArticleSummary].self)
		let references = try shown.map { try jsonObject(["accountID": $0.accountID, "articleID": $0.articleID]) }.joined(separator: ", ")
		let resorted = try await call("articles.sort", params: #"{"articles": [\#(references)], "sort": {"key": "date", "ascending": true}}"#, as: [ArticleReference].self)
		#expect(resorted.map(\.articleID) == shown.reversed().map(\.articleID))

		let error = try await callExpectingError("articles.fetch", params: #"{"selection": {"kind": "unread"}, "sort": {"key": "color", "ascending": true}}"#)
		#expect(error.code == "invalidParams")
	}

	@Test func articlesRenderWithTheSharedRenderer() async throws {
		let feed = try await makeFeed(url: "https://render.example.invalid/feed.xml", items: [("post", "Rendered post", Self.rfc822Date(hoursAgo: 1))])
		defer {
			removeFeed(feed)
		}
		let article = try #require(try await call("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}}"#, as: [ArticleSummary].self).first)

		let page = try await call("article.render", params: #"{"accountID": "OnMyMac", "articleID": "\#(article.articleID)", "textSize": "large"}"#, as: RenderedPageResult.self)
		#expect(page.title == "Rendered post")
		#expect(page.html.contains("<p>Body of post</p>"))
		#expect(page.html.contains("largeText"))
		#expect(page.html.contains("<meta charset=\"utf-8\">"), "the Windows page template")
		#expect(page.html.contains("Articles Feed"), "the feed name in the header")
		// The stylesheet's iOS-only block keeps its [[font-size]] macro, as on the Mac; check the body.
		let body = try #require(page.html.components(separatedBy: "<body>").last)
		#expect(!body.contains("[["), "every template macro is filled")
		#expect(page.baseURL == "https://render.example.invalid/post")

		let message = try await call("article.renderMessage", params: #"{"message": "No <selection>"}"#, as: RenderedPageResult.self)
		#expect(message.html.contains("No &lt;selection&gt;"))

		let scripts = try await call("article.scripts", as: ArticleScriptsResult.self)
		#expect(scripts.scripts.count == 2)
		#expect(scripts.scripts.first?.contains("processPage") == true)
	}

	@Test func feedIconsFallBackToGeneratedAndBrandedIcons() async throws {
		// No network in tests: a feed gets the generated icon, the template tinted by its URL's color.
		let feed = try await makeFeed(url: "https://icons.example.invalid/feed.xml", items: [("one", "One", Self.rfc822Date(hoursAgo: 1))])
		defer {
			removeFeed(feed)
		}
		let generated = try await call("icons.feed", params: #"{"accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}"#, as: IconResultForTest.self)
		let generatedPNG = try #require(Data(base64Encoded: generated.png))
		#expect(Array(generatedPNG.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
		#expect(generated.width == 144 && generated.height == 144)
		#expect(generated.isBackgroundSuppressed)

		// The article's icon is the feed's when it has no single author with an avatar.
		let article = try #require(try await call("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}}"#, as: [ArticleSummary].self).first)
		let articleIcon = try await call("icons.article", params: #"{"accountID": "OnMyMac", "articleID": "\#(article.articleID)"}"#, as: IconResultForTest.self)
		#expect(articleIcon.png == generated.png)

		// NetNewsWire's own feed shows its icon.
		let branded = try await makeFeed(url: "https://netnewswire.blog/test-feed.xml", items: [])
		defer {
			removeFeed(branded)
		}
		branded.homePageURL = "https://netnewswire.blog/"
		let brandedIcon = try await call("icons.feed", params: #"{"accountID": "OnMyMac", "feedID": "\#(branded.feedID)"}"#, as: IconResultForTest.self)
		#expect(brandedIcon.width == 354)
		#expect(!brandedIcon.isBackgroundSuppressed)
	}

	@Test func themesListRenderInstallAndDelete() async throws {
		let themes = try await call("themes.list", as: [ThemeInfoForTest].self)
		#expect(themes.first?.isDefault == true, "the default theme is first")
		let sepia = try #require(themes.first { $0.name == "Sepia" })
		#expect(sepia.isAppTheme)

		let feed = try await makeFeed(url: "https://themes.example.invalid/feed.xml", items: [("post", "Themed", Self.rfc822Date(hoursAgo: 1))])
		defer {
			removeFeed(feed)
		}
		let article = try #require(try await call("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}}"#, as: [ArticleSummary].self).first)
		let reference = #""accountID": "OnMyMac", "articleID": "\#(article.articleID)""#
		let defaultPage = try await call("article.render", params: "{\(reference)}", as: RenderedPageResult.self)
		let sepiaPage = try await call("article.render", params: #"{\#(reference), "themeName": "Sepia"}"#, as: RenderedPageResult.self)
		// Sepia's paper color, from Themes/Sepia.nnwtheme/stylesheet.css.
		let sepiaBackground = "background-color: rgb(248, 241, 227)"
		#expect(sepiaPage.html.contains(sepiaBackground))
		#expect(!defaultPage.html.contains(sepiaBackground))
		let missing = try await call("article.render", params: #"{\#(reference), "themeName": "No Such Theme"}"#, as: RenderedPageResult.self)
		#expect(missing.html == defaultPage.html, "an unknown theme falls back to the default")

		// Install a copy under another name, then delete it.
		let copy = FileManager.default.temporaryDirectory.appending(path: "Copied \(UUID().uuidString.prefix(8)).nnwtheme", directoryHint: .isDirectory)
		try FileManager.default.copyItem(at: Self.repositoryThemesFolder.appending(path: "Sepia.nnwtheme"), to: copy)
		defer {
			try? FileManager.default.removeItem(at: copy)
		}
		let installed = try await call("themes.install", params: try jsonObject(["path": copy.path]), as: ThemeInfoForTest.self)
		#expect(!installed.isAppTheme)
		#expect(try await call("themes.list", as: [ThemeInfoForTest].self).contains { $0.name == installed.name && !$0.isAppTheme })
		_ = try await call("themes.delete", params: try jsonObject(["name": installed.name]), as: EmptyResult.self)
		#expect(try await !call("themes.list", as: [ThemeInfoForTest].self).contains { $0.name == installed.name })

		let notATheme = try await callExpectingError("themes.install", params: try jsonObject(["path": FileManager.default.temporaryDirectory.path]))
		#expect(notATheme.code == "invalidParams")
	}

	@Test func thumbnailURLsComeWithAThumbnailMode() async throws {
		let feed = try await makeFeed(url: "https://thumbs.example.invalid/feed.xml", items: [("pic", "Has a picture", Self.rfc822Date(hoursAgo: 1))],
			description: #"&lt;p&gt;Look:&lt;/p&gt;&lt;img src="https://thumbs.example.invalid/photo.jpg" width="1200" height="800"&gt;"#)
		defer {
			removeFeed(feed)
		}
		let selection = #""selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}"#
		let plain = try #require(try await call("articles.fetch", params: "{\(selection)}", as: [ArticleSummary].self).first)
		#expect(plain.thumbnailURL == nil, "no mode, no thumbnail")

		let withThumbnail = try #require(try await call("articles.fetch", params: #"{\#(selection), "thumbnailMode": "small"}"#, as: [ArticleSummary].self).first)
		let thumbnailURL = try #require(withThumbnail.thumbnailURL)
		#expect(thumbnailURL == "https://thumbs.example.invalid/photo.jpg")

		// No network in tests: the image is pending, and asking doesn't block.
		let thumbnail = try await call("thumbnails.get", params: try jsonObject(["url": thumbnailURL, "mode": "small"]), as: ThumbnailResultForTest.self)
		#expect(thumbnail.isPending)
		#expect(thumbnail.png == nil)

		let badMode = try await callExpectingError("thumbnails.get", params: try jsonObject(["url": thumbnailURL, "mode": "huge"]))
		#expect(badMode.code == "invalidParams")
	}

	@Test func markingSendsAStatusesChangedEvent() async throws {
		let feed = try await makeFeed(url: "https://events.example.invalid/feed.xml", items: [("one", "One", Self.rfc822Date(hoursAgo: 1))])
		defer {
			removeFeed(feed)
		}
		let article = try #require(try await call("articles.fetch", params: #"{"selection": {"kind": "feed", "accountID": "OnMyMac", "feedID": "\#(feed.feedID)"}}"#, as: [ArticleSummary].self).first)

		Self.events.removeAll()
		_ = try await call("articles.mark", params: #"{"articles": [{"accountID": "OnMyMac", "articleID": "\#(article.articleID)"}], "key": "read", "flag": true}"#, as: EmptyResult.self)
		await waitForEvents()

		let statusEvents = Self.events.filter { $0.kind == .statusesChanged }
		#expect(statusEvents.count == 1, "events in one turn are coalesced")
		#expect(statusEvents.first?.articleIDs?.contains(article.articleID) == true)
		#expect(Self.events.contains { $0.kind == .unreadCountsChanged })
	}

	@Test func newArticlesFromFeedsWithNotificationsOnAreAnnouncedAndReadOnesWithdrawn() async throws {
		let feed = try await makeFeed(url: "https://notify.example.invalid/feed.xml", items: [("n1", "Notify me", Self.rfc822Date(hoursAgo: 1))])
		defer {
			removeFeed(feed)
		}
		let account = try #require(AccountManager.shared.existingAccount(accountID: "OnMyMac"))
		let articles = await account.fetchArticlesAsync(.feed(feed))

		// Off by default, as on the Mac: nothing to announce.
		Self.events.removeAll()
		Self.service.enqueueNewArticleNotices(articles)
		await waitForEvents()
		#expect(!Self.events.contains { $0.kind == .newArticles })

		_ = try await call("feeds.setNotifications", params: #"{"accountID": "OnMyMac", "feedID": "\#(feed.feedID)", "enabled": true}"#, as: EmptyResult.self)
		let sidebar = try await call("sidebar.get", as: SidebarSnapshot.self)
		#expect(sidebar.accounts.flatMap(\.feeds).first { $0.feedID == feed.feedID }?.notifiesAboutNewArticles == true)

		Self.events.removeAll()
		Self.service.enqueueNewArticleNotices(articles)
		await waitForEvents()
		let notice = try #require(Self.events.first { $0.kind == .newArticles }?.newArticles?.first)
		#expect(notice.feedID == feed.feedID && !notice.feedName.isEmpty)
		#expect(notice.title == "Notify me")

		// Marked read: its notification is withdrawn.
		Self.events.removeAll()
		_ = try await call("articles.mark", params: #"{"articles": [{"accountID": "OnMyMac", "articleID": "\#(notice.articleID)"}], "key": "read", "flag": true}"#, as: EmptyResult.self)
		await waitForEvents()
		#expect(Self.events.first { $0.kind == .articlesRead }?.articleIDs == [notice.articleID])

		// Read articles aren't announced.
		Self.events.removeAll()
		Self.service.enqueueNewArticleNotices(await account.fetchArticlesAsync(.feed(feed)))
		await waitForEvents()
		#expect(!Self.events.contains { $0.kind == .newArticles })
	}
}

// MARK: - Helpers

private struct CoreInfoResult: Decodable {
	let version: String
	let dataFolder: String
}

private struct EmptyResult: Decodable {}

private struct RenderedPageResult: Decodable {
	let html: String
	let title: String
	let baseURL: String
}

private struct IconResultForTest: Decodable {
	let png: String
	let width: Int
	let height: Int
	let isDark: Bool
	let isBright: Bool
	let isBackgroundSuppressed: Bool
}

private struct ThemeInfoForTest: Decodable {
	let name: String
	let isAppTheme: Bool
	let isDefault: Bool
}

private struct ThumbnailResultForTest: Decodable {
	let png: String?
	let isPending: Bool
}

private struct ArticleScriptsResult: Decodable {
	let scripts: [String]
}

private struct ExportedOPML: Decodable {
	let opml: String
}

private struct AccountTypeResult: Decodable {
	let type: String
	let name: String
	let needsAPIURL: Bool
}

private struct AddedAccountResult: Decodable {
	let accountID: String
	let name: String
}

private struct OpenedURLActionResult: Decodable, Equatable {
	let kind: String
	let url: String?
}

@MainActor private final class Counter {
	var count = 0
}

private struct ErrorBody: Decodable {
	let code: String
	let message: String
}

@MainActor private extension CoreServiceTests {

	static var events = [CoreEvent]()

	/// The repository's Themes folder, which the Windows app ships next to its exe.
	static let repositoryThemesFolder = URL(filePath: #filePath).deletingLastPathComponent()
		.appending(path: "../../../../Themes", directoryHint: .isDirectory).standardizedFileURL

	static let service: CoreService = {
		let service = CoreService { event in
			CoreServiceTests.events.append(event)
		}
		service.appThemesFolder = repositoryThemesFolder
		service.start()
		return service
	}()

	struct Envelope<Result: Decodable>: Decodable {
		let result: Result?
		let error: ErrorBody?
	}

	func call<Result: Decodable>(_ method: String, params: String? = nil, as type: Result.Type) async throws -> Result {
		let response = await Self.service.handle(method: method, paramsJSON: params)
		let envelope = try CoreService.decoder.decode(Envelope<Result>.self, from: Data(response.utf8))
		if let error = envelope.error {
			Issue.record("\(method) failed: \(error.code): \(error.message)")
		}
		return try #require(envelope.result, "\(method) returned \(response)")
	}

	func callExpectingError(_ method: String, params: String? = nil) async throws -> ErrorBody {
		let response = await Self.service.handle(method: method, paramsJSON: params)
		let envelope = try CoreService.decoder.decode(Envelope<CoreService.Empty>.self, from: Data(response.utf8))
		return try #require(envelope.error, "\(method) should have failed: \(response)")
	}

	func jsonObject(_ object: [String: String]) throws -> String {
		String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
	}

	func localAccountInfo() async throws -> AccountInfo {
		let sidebar = try await call("sidebar.get", as: SidebarSnapshot.self)
		return try #require(sidebar.accounts.first { $0.accountID == "OnMyMac" })
	}

	/// A feed in the local account with articles stored from `items` (guid, title, date) — no network.
	func makeFeed(url: String, items: [(guid: String, title: String, date: String)], description: String? = nil) async throws -> Feed {
		let account = AccountManager.shared.defaultAccount
		let feed = account.createFeed(with: "Articles Feed", url: url, feedID: url, homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)

		if !items.isEmpty {
			let base = url.replacingOccurrences(of: "/feed.xml", with: "")
			let itemsXML = items.map { item in
				"<item><guid>\(base)/\(item.guid)</guid><title>\(item.title)</title><link>\(base)/\(item.guid)</link><pubDate>\(item.date)</pubDate><description>\(description ?? "&lt;p&gt;Body of \(item.guid)&lt;/p&gt;")</description></item>"
			}.joined()
			let rss = #"<?xml version="1.0"?><rss version="2.0"><channel><title>Articles Feed</title><link>\#(base)/</link>\#(itemsXML)</channel></rss>"#
			let parsedFeed = try #require(try await FeedParser.parse(ParserData(url: url, data: Data(rss.utf8))))
			_ = await account.updateAsync(feed: feed, parsedFeed: parsedFeed)
		}
		return feed
	}

	func removeFeed(_ feed: Feed) {
		AccountManager.shared.defaultAccount.removeFeedFromTreeAtTopLevel(feed)
	}

	/// Recent, since articles older than ArticleStatus.staleIntervalInSeconds arrive already read.
	static func rfc822Date(hoursAgo: Int) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "GMT")
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
		return formatter.string(from: Date().addingTimeInterval(-Double(hoursAgo) * 60 * 60))
	}

	/// Lets the coalesced events from this main-queue turn go out.
	func waitForEvents() async {
		for _ in 0..<5 {
			await Task.yield()
			try? await Task.sleep(for: .milliseconds(20))
		}
	}
}
