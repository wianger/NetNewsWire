//
//  DownloadSession.swift
//  RSWeb
//
//  Created by Brent Simmons on 3/12/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import RSCore

// Create a DownloadSessionDelegate, then create a DownloadSession.
// To download things: call download with a set of URLs. DownloadSession will call the various delegate methods.

@MainActor public protocol DownloadSessionDelegate {

	func downloadSession(_ downloadSession: DownloadSession, conditionalGetInfoFor: URL) -> HTTPConditionalGetInfo?
	func downloadSession(_ downloadSession: DownloadSession, didReceiveResponse url: URL)
	func downloadSession(_ downloadSession: DownloadSession, didSkip url: URL, reason: String)
	func downloadSession(_ downloadSession: DownloadSession, downloadDidComplete: URL, response: URLResponse?, data: Data, error: NSError?)
	func downloadSession(_ downloadSession: DownloadSession, shouldContinueAfterReceivingData: Data, url: URL) -> Bool
	func downloadSession(_ downloadSession: DownloadSession, httpError statusCode: Int, url: URL)
	func downloadSession(_ downloadSession: DownloadSession, didFollowRedirectFor url: URL, from fromURL: URL, to toURL: URL, statusCode: Int)
	func downloadSessionDidComplete(_ downloadSession: DownloadSession)
}

struct HTTP4xxResponse {
	let statusCode: Int
	let date: Date

	init(_ statusCode: Int) {
		self.statusCode = statusCode
		self.date = Date()
	}
}

@MainActor public final class DownloadSession: NSObject, ProgressInfoReporter {
	private var urlSession: URLSession!
	private var tasksInProgress = Set<URLSessionTask>()
	private var tasksPending = Set<URLSessionTask>()
	private var taskToInfoDictionary = [URLSessionTask: DownloadInfo]()
	private var urlsInSession = Set<URL>()
	private let delegate: DownloadSessionDelegate
	private var redirectCache = [URL: URL]()
	private var queue = [URL]()
#if os(Windows)
	/// On Windows, downloads go through WinHTTP (see WinHTTPClient) and are tracked here instead of as URLSessionTasks.
	private var windowsDownloads = [ObjectIdentifier: WindowsDownload]()
#endif

	public var progressInfo = ProgressInfo() {
		didSet {
			if progressInfo != oldValue {
				postProgressInfoDidChangeNotification()
			}
		}
	}

	// 429 Too Many Requests responses
	private var retryAfterMessages = [String: HTTPResponse429]()

	/// URLs with 400-499 responses (except for 429).
	/// These URLs are skipped for a period of time.
	private var http4xxResponses = [URL: HTTP4xxResponse]()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "DownloadSession")

	public init(delegate: DownloadSessionDelegate) {

		self.delegate = delegate

		super.init()

		urlSession = makeURLSession()
	}

	/// Invalidate the session and build a new one, discarding pooled connections,
	/// which go dead while the app is suspended.
	public func recreateURLSession() {
		urlSession.invalidateAndCancel()
		urlSession = makeURLSession()
	}

	private func makeURLSession() -> URLSession {
		let sessionConfiguration = URLSessionConfiguration.ephemeral
		sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
		sessionConfiguration.timeoutIntervalForRequest = 15.0
		sessionConfiguration.timeoutIntervalForResource = 60.0
#if canImport(Darwin)
		sessionConfiguration.waitsForConnectivity = true // Not settable in swift-corelibs-foundation.
#endif
		sessionConfiguration.httpShouldSetCookies = false
		sessionConfiguration.httpCookieAcceptPolicy = .never
		sessionConfiguration.httpMaximumConnectionsPerHost = 1
		sessionConfiguration.httpCookieStorage = nil
		sessionConfiguration.urlCache = nil

		if let userAgentHeaders = UserAgent.headers() {
			sessionConfiguration.httpAdditionalHeaders = userAgentHeaders
		}

		return URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: OperationQueue.main)
	}

	deinit {
		urlSession.invalidateAndCancel()
	}

	// MARK: - API

	public func cancelAll() {
		queue.removeAll()
#if os(Windows)
		// As with URLSession, each canceled download still completes, with a cancellation error.
		for download in windowsDownloads.values {
			download.task?.cancel()
		}
#endif
		urlSession.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
			for task in dataTasks {
				task.cancel()
			}
			for task in uploadTasks {
				task.cancel()
			}
			for task in downloadTasks {
				task.cancel()
			}
			Task { @MainActor in
				self.updateProgress()
			}
		}
	}

	@MainActor public func download(_ urls: Set<URL>) {
		cleanUp4xxResponsesCache()

		let filteredURLs = Self.filteredURLs(urls)

		if filteredURLs.isEmpty {
			delegate.downloadSessionDidComplete(self)
			return
		}

		for url in filteredURLs {
			addDataTask(url)
		}

		urlsInSession = filteredURLs
		updateProgress()
	}
}

// MARK: - URLSessionTaskDelegate

extension DownloadSession: @preconcurrency URLSessionTaskDelegate {

	public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		MainActor.assumeIsolated {
			defer {
				removeTask(task)
			}

			guard let info = infoForTask(task) else {
				if let url = task.originalRequest?.url {
					Self.logger.debug("DownloadSession: no task info found for \(url)")
				} else {
					Self.logger.debug("DownloadSession: no task info found for unknown URL")
				}
				return
			}

			delegate.downloadSession(self, downloadDidComplete: info.url, response: info.urlResponse, data: info.data, error: error as NSError?)
		}
	}

	private static let redirectStatusCodes = Set([HTTPResponseCode.redirectPermanent, HTTPResponseCode.redirectTemporary, HTTPResponseCode.redirectVeryTemporary, HTTPResponseCode.redirectPermanentPreservingMethod])

	public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {

		if Self.redirectStatusCodes.contains(response.statusCode) {
			if let oldURL = task.originalRequest?.url, let newURL = request.url {
				cacheRedirect(oldURL, newURL)
			}
		}

		if let taskInfo = infoForTask(task), let toURL = request.url {
			let fromURL = response.url ?? taskInfo.url
			delegate.downloadSession(self, didFollowRedirectFor: taskInfo.url, from: fromURL, to: toURL, statusCode: response.statusCode)
		}

		var modifiedRequest = request

		modifiedRequest.addSpecialCaseUserAgentIfNeeded()

		completionHandler(modifiedRequest)
	}
}

// MARK: - URLSessionDataDelegate

extension DownloadSession: @preconcurrency URLSessionDataDelegate {

	public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
		MainActor.assumeIsolated {
			defer {
				updateProgress()
			}

			tasksInProgress.insert(dataTask)
			tasksPending.remove(dataTask)

			let taskInfo = infoForTask(dataTask)
			if let taskInfo {
				taskInfo.urlResponse = response
				delegate.downloadSession(self, didReceiveResponse: taskInfo.url)
			}

			let statusCode = response.forcedStatusCode
			if statusCode >= 400 {
				Self.logger.debug("DownloadSession: canceling task due to >= 400 response \(response)")

				if let url = taskInfo?.url {
					delegate.downloadSession(self, httpError: statusCode, url: url)
				}

				completionHandler(.cancel)
				removeTask(dataTask)

				if statusCode == HTTPResponseCode.tooManyRequests {
					handle429Response(dataTask, response)
				} else if (400...499).contains(statusCode), let url = response.url {
					cache4xxResponse(url: url, response: HTTP4xxResponse(statusCode))
				}

				return
			}

			addDataTaskFromQueueIfNecessary()
			completionHandler(.allow)
		}
	}

	public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		MainActor.assumeIsolated {
			guard let info = infoForTask(dataTask) else {
				return
			}
			info.addData(data)

			if !delegate.downloadSession(self, shouldContinueAfterReceivingData: info.data, url: info.url) {
				dataTask.cancel()
				removeTask(dataTask)
			}
		}
	}
}

// MARK: - Private

private extension DownloadSession {

	@MainActor func addDataTask(_ url: URL) {

		guard pendingTaskCount < 500 else {
			queue.insert(url, at: 0)
			return
		}

		// If received permanent redirect earlier, use that URL.
		let urlToUse = cachedRedirect(for: url) ?? url

		if requestShouldBeDroppedDueToActive429(urlToUse) {
			Self.logger.info("DownloadSession: Dropping request for previous 429: \(urlToUse)")
			delegate.downloadSession(self, didSkip: url, reason: "Skipped — previous 429 Too Many Requests")
			addDataTaskFromQueueIfNecessary()
			return
		}
		if requestShouldBeDroppedDueToPrevious400(urlToUse) {
			Self.logger.info("DownloadSession: Dropping request for previous 400-499: \(urlToUse)")
			delegate.downloadSession(self, didSkip: url, reason: "Skipped — previous 4xx error")
			addDataTaskFromQueueIfNecessary()
			return
		}

		let urlRequest: URLRequest = {
			var request = URLRequest(url: urlToUse)
			if let conditionalGetInfo = delegate.downloadSession(self, conditionalGetInfoFor: url) {
				conditionalGetInfo.addRequestHeadersToURLRequest(&request)
			}
			request.addSpecialCaseUserAgentIfNeeded()
			return request
		}()

		Self.logger.debug("DownloadSession: adding dataTask for \(urlToUse)")
#if os(Windows)
		startWindowsDownload(urlRequest, info: DownloadInfo(url))
#else
		let task = urlSession.dataTask(with: urlRequest)

		let info = DownloadInfo(url)
		taskToInfoDictionary[task] = info

		tasksPending.insert(task)
		task.resume()
#endif
	}

	var pendingTaskCount: Int {
#if os(Windows)
		windowsDownloads.values.count(where: { !$0.isInProgress })
#else
		tasksPending.count
#endif
	}

	var inProgressTaskCount: Int {
#if os(Windows)
		windowsDownloads.values.count(where: { $0.isInProgress })
#else
		tasksInProgress.count
#endif
	}

	@MainActor func addDataTaskFromQueueIfNecessary() {
		guard pendingTaskCount < 500, let url = queue.popLast() else { return }
		addDataTask(url)
	}

	func infoForTask(_ task: URLSessionTask) -> DownloadInfo? {
		return taskToInfoDictionary[task]
	}

	@MainActor func removeTask(_ task: URLSessionTask) {
		tasksInProgress.remove(task)
		tasksPending.remove(task)
		taskToInfoDictionary[task] = nil

		addDataTaskFromQueueIfNecessary()

		updateProgress()
	}

	func urlStringIsDisallowedRedirect(_ urlString: String) -> Bool {

		// Hotels and similar often do permanent redirects. We can catch some of those.

		let s = urlString.lowercased()
		let badStrings = ["solutionip", "lodgenet", "monzoon", "landingpage", "btopenzone", "register", "login", "authentic"]

		for oneBadString in badStrings {
			if s.contains(oneBadString) {
				return true
			}
		}

		return false
	}

	func cacheRedirect(_ oldURL: URL, _ newURL: URL) {
		if urlStringIsDisallowedRedirect(newURL.absoluteString) {
			return
		}
		redirectCache[oldURL] = newURL
	}

	func cachedRedirect(for url: URL) -> URL? {

		// Follow chains of redirects, but avoid loops.

		var urls = Set<URL>()
		urls.insert(url)

		var currentURL = url

		while true {

			if let oneRedirectURL = redirectCache[currentURL] {

				if urls.contains(oneRedirectURL) {
					// Cycle. Bail.
					return nil
				}
				urls.insert(oneRedirectURL)
				currentURL = oneRedirectURL
			} else {
				break
			}
		}

		if currentURL == url {
			return nil
		}
		return currentURL
	}

	// MARK: - Download Progress

	@MainActor func updateProgress() {
		let numberOfTasks = urlsInSession.count
		let numberRemaining: Int
		let numberCompleted: Int
		if numberOfTasks == 0 {
			numberRemaining = 0
			numberCompleted = 0
		} else {
			numberRemaining = pendingTaskCount + inProgressTaskCount + queue.count
			numberCompleted = numberOfTasks - numberRemaining
		}

		progressInfo = ProgressInfo(numberOfTasks: numberOfTasks,
									numberCompleted: numberCompleted,
									numberRemaining: numberRemaining)

		// Completed?
		if progressInfo.numberOfTasks > 0 && progressInfo.numberRemaining < 1 {
			delegate.downloadSessionDidComplete(self)
			urlsInSession.removeAll()
		}
	}
}

// MARK: - 429 Too Many Requests

extension DownloadSession {

	@MainActor func handle429Response(_ dataTask: URLSessionDataTask, _ response: URLResponse) {
		handle429Response(url: dataTask.currentRequest?.url ?? dataTask.originalRequest?.url, response: response)
	}

	@MainActor func handle429Response(url: URL?, response: URLResponse) {

		guard let message = createHTTPResponse429(url: url, response) else {
			return
		}

		retryAfterMessages[message.host] = message
		cancelAndRemoveTasksWithHost(message.host)
	}

	// Default for sites that don’t send a value.
	static let defaultRetryAfter: TimeInterval = 10 * 60 // 10 minutes

	func createHTTPResponse429(url: URL?, _ response: URLResponse) -> HTTPResponse429? {

		guard let url else {
			return nil
		}
		guard let httpResponse = response as? HTTPURLResponse else {
			return nil
		}

		let parsedRetryAfter: TimeInterval? = {
			if let retryAfterValue = httpResponse.value(forHTTPHeaderField: HTTPResponseHeader.retryAfter),
			   let parsed = TimeInterval(retryAfterValue),
			   parsed > 0 {
				return parsed
			}
			return nil
		}()
		let retryAfter = parsedRetryAfter ?? Self.defaultRetryAfter

		return HTTPResponse429(url: url, retryAfter: retryAfter)
	}

	@MainActor func cancelAndRemoveTasksWithHost(_ host: String) {

		cancelAndRemoveTasksWithHost(host, in: tasksInProgress)
		cancelAndRemoveTasksWithHost(host, in: tasksPending)
#if os(Windows)
		cancelAndRemoveWindowsDownloadsWithHost(host)
#endif
	}

	@MainActor func cancelAndRemoveTasksWithHost(_ host: String, in tasks: Set<URLSessionTask>) {

		let tasksToRemove = Self.tasksWithHost(host, in: tasks)

		for task in tasksToRemove {
			task.cancel()
		}
		for task in tasksToRemove {
			removeTask(task)
		}
	}

	/// Tasks whose request host matches `host` exactly, ignoring case.
	nonisolated static func tasksWithHost(_ host: String, in tasks: Set<URLSessionTask>) -> Set<URLSessionTask> {
		let lowercaseHost = host.lowercased(with: localeForLowercasing)
		return tasks.filter { $0.lowercaseHost == lowercaseHost }
	}

	func requestShouldBeDroppedDueToActive429(_ url: URL) -> Bool {

		guard let host = url.host()?.lowercased(with: localeForLowercasing) else {
			return false
		}
		guard let retryAfterMessage = retryAfterMessages[host] else {
			return false
		}

		if retryAfterMessage.resumeDate < Date() {
			retryAfterMessages[host] = nil
			return false
		}

		return true
	}
}

// MARK: - Private

private extension DownloadSession {

	// MARK: - 400-499 responses

	func cache4xxResponse(url: URL, response: HTTP4xxResponse) {
		guard !url.isYoutubeURL else {
			return
		}
		http4xxResponses[url] = response
	}

	// Remove 4xx responses placed in the cache more than a while ago.
	func cleanUp4xxResponsesCache() {
		let oldDate = Date().bySubtracting(hours: 53)

		for url in http4xxResponses.keys {
			guard let response = http4xxResponses[url] else {
				continue
			}
			if response.date < oldDate {
				http4xxResponses[url] = nil
			}
		}
	}

	func requestShouldBeDroppedDueToPrevious400(_ url: URL) -> Bool {
		if http4xxResponses[url] != nil {
			return true
		}
		if let redirectedURL = cachedRedirect(for: url), http4xxResponses[redirectedURL] != nil {
			return true
		}

		return false
	}

	// MARK: - Filtering URLs

	static private let openRSSOrgMinimumRefreshInterval: TimeInterval = 60 * 60 // arbitrary
	static private let lastOpenRSSOrgFeedRefreshKey = "lastOpenRSSOrgFeedRefresh"
	static private var lastOpenRSSOrgFeedRefresh: Date {
		get {
			UserDefaults.standard.object(forKey: lastOpenRSSOrgFeedRefreshKey) as? Date ?? Date.distantPast
		}
		set {
			UserDefaults.standard.set(newValue, forKey: lastOpenRSSOrgFeedRefreshKey)
		}
	}

	static private var canDownloadFromOpenRSSOrg: Bool {
		let okayToDownloadDate = lastOpenRSSOrgFeedRefresh + openRSSOrgMinimumRefreshInterval
		return Date() > okayToDownloadDate
	}

	static func filteredURLs(_ urls: Set<URL>) -> Set<URL> {

		// Possibly remove some openrss.org URLs.
		// Can be extended later if necessary.

		if canDownloadFromOpenRSSOrg {
			// Allow only one feed from openrss.org per refresh session
			lastOpenRSSOrgFeedRefresh = Date()
			return urls.byRemovingAllButOneRandomOpenRSSOrgURL()
		}

		return urls.byRemovingOpenRSSOrgURLs()
	}
}

extension URLSessionTask {

	var lowercaseHost: String? {
		guard let request = currentRequest ?? originalRequest else {
			return nil
		}
		return request.url?.host()?.lowercased(with: localeForLowercasing)
	}
}

// MARK: - DownloadInfo

private final class DownloadInfo {

	let url: URL
	var data = Data()
	var urlResponse: URLResponse?

	init(_ url: URL) {

		self.url = url
	}

	func addData(_ d: Data) {

		data.append(d)
	}
}

#if os(Windows)

// MARK: - Windows

/// A download in flight through WinHTTP: what a URLSessionTask and its DownloadInfo are elsewhere.
@MainActor private final class WindowsDownload {
	let info: DownloadInfo
	/// The URL requested — after a cached permanent redirect, if there was one.
	let requestURL: URL
	/// Where redirects have led, for matching a 429's host.
	var currentURL: URL
	/// Has its response. Until then, pending.
	var isInProgress = false
	var task: Task<Void, Never>?

	init(info: DownloadInfo, requestURL: URL) {
		self.info = info
		self.requestURL = requestURL
		self.currentURL = requestURL
	}
}

/// The same steps as the URLSession delegate methods above, in the same order, for WinHTTP's callbacks.
private extension DownloadSession {

	/// The user agent, as the URLSession configuration adds it.
	static let winHTTPAdditionalHeaders: [String: String] = UserAgent.headers()?.reduce(into: [String: String]()) { headers, header in
		if let field = header.key.base as? String {
			headers[field] = header.value
		}
	} ?? [:]

	func startWindowsDownload(_ request: URLRequest, info: DownloadInfo) {
		let download = WindowsDownload(info: info, requestURL: request.url ?? info.url)
		let key = ObjectIdentifier(download)
		windowsDownloads[key] = download

		let handlers = WinHTTPHandlers(
			willRedirect: { [weak self] response, newRequest in
				await self?.windowsDownload(key, willRedirect: response, newRequest: newRequest)
			},
			didReceiveResponse: { [weak self] response in
				await self?.windowsDownload(key, didReceive: response) ?? false
			},
			didReceiveData: { [weak self] data in
				await self?.windowsDownload(key, didReceive: data) ?? false
			}
		)
		download.task = Task { [weak self] in
			var downloadError: Error?
			do {
				// The timeouts of the URLSession configuration in makeURLSession.
				_ = try await WinHTTPClient.shared.data(for: request, additionalHeaders: Self.winHTTPAdditionalHeaders, timeout: 15, resourceTimeout: 60, handlers: handlers)
			} catch {
				downloadError = error
			}
			self?.windowsDownload(key, didCompleteWithError: downloadError)
		}
		updateProgress()
	}

	/// As urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:).
	func windowsDownload(_ key: ObjectIdentifier, willRedirect response: HTTPURLResponse, newRequest request: URLRequest) -> URLRequest? {
		guard let download = windowsDownloads[key] else {
			return nil
		}
		if Self.redirectStatusCodes.contains(response.statusCode), let newURL = request.url {
			cacheRedirect(download.requestURL, newURL)
		}
		if let toURL = request.url {
			let fromURL = response.url ?? download.info.url
			delegate.downloadSession(self, didFollowRedirectFor: download.info.url, from: fromURL, to: toURL, statusCode: response.statusCode)
			download.currentURL = toURL
		}
		var modifiedRequest = request
		modifiedRequest.addSpecialCaseUserAgentIfNeeded()
		return modifiedRequest
	}

	/// As urlSession(_:dataTask:didReceive:completionHandler:). False cancels the download.
	func windowsDownload(_ key: ObjectIdentifier, didReceive response: HTTPURLResponse) -> Bool {
		guard let download = windowsDownloads[key] else {
			return false
		}
		defer {
			updateProgress()
		}

		download.isInProgress = true
		download.info.urlResponse = response
		delegate.downloadSession(self, didReceiveResponse: download.info.url)

		let statusCode = response.forcedStatusCode
		if statusCode >= 400 {
			Self.logger.debug("DownloadSession: canceling task due to >= 400 response \(response)")
			delegate.downloadSession(self, httpError: statusCode, url: download.info.url)
			removeWindowsDownload(key)

			if statusCode == HTTPResponseCode.tooManyRequests {
				handle429Response(url: download.currentURL, response: response)
			} else if (400...499).contains(statusCode), let url = response.url {
				cache4xxResponse(url: url, response: HTTP4xxResponse(statusCode))
			}
			return false
		}

		addDataTaskFromQueueIfNecessary()
		return true
	}

	/// As urlSession(_:dataTask:didReceive:). False cancels the download.
	func windowsDownload(_ key: ObjectIdentifier, didReceive data: Data) -> Bool {
		guard let download = windowsDownloads[key] else {
			return false
		}
		download.info.addData(data)
		if !delegate.downloadSession(self, shouldContinueAfterReceivingData: download.info.data, url: download.info.url) {
			removeWindowsDownload(key)
			return false
		}
		return true
	}

	/// As urlSession(_:task:didCompleteWithError:). Downloads already removed — after a 4xx, or when
	/// the delegate stopped them — don't complete, as their URLSession tasks find no info.
	func windowsDownload(_ key: ObjectIdentifier, didCompleteWithError error: Error?) {
		guard let download = windowsDownloads[key] else {
			return
		}
		removeWindowsDownload(key)
		delegate.downloadSession(self, downloadDidComplete: download.info.url, response: download.info.urlResponse, data: download.info.data, error: error as NSError?)
	}

	func removeWindowsDownload(_ key: ObjectIdentifier) {
		windowsDownloads[key] = nil
		addDataTaskFromQueueIfNecessary()
		updateProgress()
	}

	func cancelAndRemoveWindowsDownloadsWithHost(_ host: String) {
		let lowercaseHost = host.lowercased(with: localeForLowercasing)
		let matching = windowsDownloads.filter { $0.value.currentURL.host()?.lowercased(with: localeForLowercasing) == lowercaseHost }
		for (key, download) in matching {
			download.task?.cancel()
			removeWindowsDownload(key)
		}
	}
}

#endif
