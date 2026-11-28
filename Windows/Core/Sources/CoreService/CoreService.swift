//
//  CoreService.swift
//  CoreService
//
//  The Windows app's whole view of the core: JSON requests in, JSON responses and
//  events out. It is plain Swift so tests can drive it; NetNewsWireCore exports it
//  over the C ABI. Runs on the main actor — on Windows, the WinUI UI thread.
//
//  A response is `{"result": …}` or `{"error": {"code": …, "message": …}}`.
//

import Foundation
import RSCore
import Articles
import Account

@MainActor public final class CoreService {

	public typealias EventHandler = @MainActor (CoreEvent) -> Void

	nonisolated public static let version = "NetNewsWireCore 0.2.0 (M3)"

	let accountManager: AccountManager
	let themeStore = ThemeStore()

	/// The .nnwtheme folders that ship with the app. The Windows app keeps them in Themes next to the exe.
	public var appThemesFolder: URL? {
		get { themeStore.appThemesFolder }
		set { themeStore.appThemesFolder = newValue }
	}
	private let eventHandler: EventHandler
	private var pendingEvents = PendingEvents()

	/// Set by `app.prepareToQuit`. No events after it: the app is tearing down its UI thread.
	private(set) var isQuitting = false

	/// The Mac's AccountRefreshTimer and ArticleStatusSyncTimer. See CoreService+Timers.
	private(set) lazy var refreshScheduler = RefreshScheduler { [weak self] in
		self?.accountManager.refreshAllWithoutWaiting()
	}
	private(set) lazy var statusSyncScheduler = StatusSyncScheduler { [weak self] in
		await self?.accountManager.syncArticleStatusAll() ?? false
	}
	private var isFlushScheduled = false
	private var isStarted = false

	/// AccountManager.start() may be called only once per process.
	private static var didStartAccountManager = false

	public init(accountManager: AccountManager = .shared, eventHandler: @escaping EventHandler) {
		self.accountManager = accountManager
		self.eventHandler = eventHandler
	}

	/// Starts the account manager and begins sending events. Call once, on the main actor.
	public func start() {
		guard !isStarted else {
			return
		}
		isStarted = true

		if !Self.didStartAccountManager {
			Self.didStartAccountManager = true
			accountManager.start()
		}
		observeNotifications()
		setUpIcons()
		observeThumbnailNotifications()
	}

	/// Handles one request. Never throws: failures come back as an error response.
	public func handle(method: String, params: Data?) async -> Data {
		do {
			let request = Request(params: params)
			return try await route(method: method, request: request)
		} catch let error as CoreServiceError {
			return Self.errorResponse(code: error.code, message: error.message)
		} catch let error as DecodingError {
			return Self.errorResponse(code: "invalidParams", message: String(describing: error))
		} catch {
			return Self.errorResponse(code: "failed", message: error.localizedDescription)
		}
	}

	/// Convenience for callers that have the params as a JSON string, and for tests.
	public func handle(method: String, paramsJSON: String?) async -> String {
		let response = await handle(method: method, params: paramsJSON.map { Data($0.utf8) })
		return String(decoding: response, as: UTF8.self)
	}
}

// MARK: - Errors

public struct CoreServiceError: Error, Sendable {
	public let code: String
	public let message: String

	static func unknownMethod(_ method: String) -> CoreServiceError {
		CoreServiceError(code: "unknownMethod", message: "No method named \(method).")
	}

	static func notFound(_ what: String) -> CoreServiceError {
		CoreServiceError(code: "notFound", message: "\(what) not found.")
	}

	static func invalidParams(_ message: String) -> CoreServiceError {
		CoreServiceError(code: "invalidParams", message: message)
	}
}

// MARK: - JSON

extension CoreService {

	nonisolated static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return encoder
	}()

	nonisolated static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()

	struct Request {
		let params: Data?

		func decode<Params: Decodable>(_ type: Params.Type) throws -> Params {
			try CoreService.decoder.decode(Params.self, from: params ?? Data("{}".utf8))
		}
	}

	private struct ResultEnvelope<Result: Encodable>: Encodable {
		let result: Result
	}

	private struct ErrorEnvelope: Encodable {
		struct Body: Encodable {
			let code: String
			let message: String
		}
		let error: Body
	}

	/// An empty JSON object, for methods with nothing to return.
	struct Empty: Codable {}

	static func response<Result: Encodable>(_ result: Result) throws -> Data {
		try encoder.encode(ResultEnvelope(result: result))
	}

	static func errorResponse(code: String, message: String) -> Data {
		(try? encoder.encode(ErrorEnvelope(error: .init(code: code, message: message)))) ?? Data(#"{"error":{"code":"failed","message":"Could not encode error."}}"#.utf8)
	}

	nonisolated public static func eventJSON(_ event: CoreEvent) -> String {
		guard let data = try? encoder.encode(event) else {
			return #"{"kind":"\#(event.kind.rawValue)"}"#
		}
		return String(decoding: data, as: UTF8.self)
	}
}

// MARK: - Events

private extension CoreService {

	struct PendingEvents {
		var kinds = Set<CoreEvent.Kind>()
		/// Nil once a status change for unknown articles arrives: then the app refetches everything.
		var changedArticleIDs: Set<String>? = Set<String>()
		var progress: RefreshProgress?
		/// Nil once a change to an unknown set of icons arrives.
		var changedIconFeedIDs: Set<String>? = Set<String>()
		var readyThumbnailURLs = Set<String>()
		var newArticles = [NewArticleNotice]()
		var readArticleIDs = Set<String>()
		var thumbnailArticleIDs = Set<String>()
	}

	func observeNotifications() {
		let center = NotificationCenter.default
		for name in [Notification.Name.ChildrenDidChange, .DisplayNameDidChange, .UserDidAddAccount, .UserDidDeleteAccount, .AccountStateDidChange, .BatchUpdateDidPerform] {
			center.addMainActorObserver(self, name: name) { service, _ in
				service.enqueue(.sidebarChanged)
			}
		}
		center.addMainActorObserver(self, name: .UnreadCountDidChange) { service, _ in
			service.enqueue(.unreadCountsChanged)
		}
		center.addMainActorObserver(self, name: .StatusesDidChange) { service, notification in
			let articleIDs = notification.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>
			service.enqueueStatusesChanged(articleIDs)
			if let articleIDs, notification.userInfo?[Account.UserInfoKey.statusKey] as? ArticleStatus.Key == .read, notification.userInfo?[Account.UserInfoKey.statusFlag] as? Bool == true {
				service.enqueueArticlesRead(articleIDs)
			}
		}
		center.addMainActorObserver(self, name: .AccountDidDownloadArticles) { service, notification in
			service.enqueue(.articlesChanged)
			if let articles = notification.userInfo?[Account.UserInfoKey.newArticles] as? Set<Article> {
				service.enqueueNewArticleNotices(articles)
			}
		}
		center.addMainActorObserver(self, name: .progressInfoDidChange, object: CombinedRefreshProgress.shared) { service, _ in
			let progress = CombinedRefreshProgress.shared.progressInfo
			service.pendingEvents.progress = RefreshProgress(numberOfTasks: progress.numberOfTasks, numberCompleted: progress.numberCompleted, numberRemaining: progress.numberRemaining, isComplete: CombinedRefreshProgress.shared.isComplete)
			service.enqueue(.refreshProgress)
		}
	}

	func enqueue(_ kind: CoreEvent.Kind) {
		pendingEvents.kinds.insert(kind)
		scheduleFlush()
	}

	func enqueueStatusesChanged(_ articleIDs: Set<String>?) {
		if let articleIDs {
			pendingEvents.changedArticleIDs?.formUnion(articleIDs)
		} else {
			pendingEvents.changedArticleIDs = nil
		}
		enqueue(.statusesChanged)
	}

	func scheduleFlush() {
		guard !isFlushScheduled else {
			return
		}
		isFlushScheduled = true
		Task { @MainActor in
			self.flushEvents()
		}
	}

	func flushEvents() {
		isFlushScheduled = false
		guard !isQuitting else {
			return
		}
		let pending = pendingEvents
		pendingEvents = PendingEvents()

		// A stable order, so the app sees structure before counts before statuses.
		let order: [CoreEvent.Kind] = [.sidebarChanged, .unreadCountsChanged, .statusesChanged, .articlesRead, .articlesChanged, .newArticles, .iconsChanged, .thumbnailsChanged, .refreshProgress]
		assert(Set(order).count == CoreEvent.Kind.allCases.count, "Every kind of event needs a place in the order")
		for kind in order where pending.kinds.contains(kind) {
			var event = CoreEvent(kind: kind)
			switch kind {
			case .statusesChanged:
				event.articleIDs = pending.changedArticleIDs.map { $0.sorted() }
			case .refreshProgress:
				event.progress = pending.progress
			case .iconsChanged:
				event.feedIDs = pending.changedIconFeedIDs.map { $0.sorted() }
			case .thumbnailsChanged:
				event.urls = pending.readyThumbnailURLs.sorted()
				event.articleIDs = pending.thumbnailArticleIDs.sorted()
			case .newArticles:
				event.newArticles = pending.newArticles
			case .articlesRead:
				event.articleIDs = pending.readArticleIDs.sorted()
			case .sidebarChanged, .unreadCountsChanged, .articlesChanged:
				break
			}
			eventHandler(event)
		}
	}
}

extension CoreService {

	/// For CoreService+Notifications.
	func enqueueNewArticles(_ notices: [NewArticleNotice]) {
		guard !notices.isEmpty else {
			return
		}
		pendingEvents.newArticles += notices
		enqueue(.newArticles)
	}

	func enqueueArticlesRead(_ articleIDs: Set<String>) {
		pendingEvents.readArticleIDs.formUnion(articleIDs)
		enqueue(.articlesRead)
	}

	/// For CoreService+Thumbnails.
	func enqueueThumbnailsChanged(urls: Set<String>, articleIDs: Set<String>) {
		pendingEvents.readyThumbnailURLs.formUnion(urls)
		pendingEvents.thumbnailArticleIDs.formUnion(articleIDs)
		enqueue(.thumbnailsChanged)
	}

	/// For CoreService+Icons: the icon notifications come from the Images module.
	func enqueueIconsChanged(_ feedIDs: Set<String>?) {
		if let feedIDs {
			pendingEvents.changedIconFeedIDs?.formUnion(feedIDs)
		} else {
			pendingEvents.changedIconFeedIDs = nil
		}
		enqueue(.iconsChanged)
	}
}

extension CoreService {

	/// As the Mac's applicationWillTerminate: save, then send unsent read and starred changes, waiting
	/// up to two seconds. Events stop first, since the app is about to tear down its UI thread.
	func prepareToQuit() async {
		isQuitting = true
		refreshScheduler.stop()
		statusSyncScheduler.stop()
		accountManager.saveAllIfNeeded()

		let sending = StatusSendState()
		Task { @MainActor in
			await self.accountManager.sendArticleStatusAll()
			sending.isDone = true
		}
		let deadline = Date().addingTimeInterval(2)
		while !sending.isDone && Date() < deadline {
			try? await Task.sleep(for: .milliseconds(50))
		}
		accountManager.saveAllIfNeeded()
	}
}

@MainActor private final class StatusSendState {
	var isDone = false
}
