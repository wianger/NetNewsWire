//
//  Downloader.swift
//  RSWeb
//
//  Created by Brent Simmons on 8/27/16.
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

public typealias DownloadCallback = @MainActor (DownloadResponse, Error?) -> Swift.Void

/// Simple downloader, for a one-shot download like an image
/// or a web page. For a download-feeds session, see DownloadSession.
/// Caches response for a short time for GET requests, unless `cachesResponse` is false. May return cached response.
/// A conditional GET isn’t cached or coalesced with other requests, since its 304 response has no body.
@MainActor public final class Downloader {
	public static let shared = Downloader()
	private let urlSession: URLSession
	private var callbacks = [URL: [(callback: DownloadCallback, fromCache: Bool)]]()
	private let cache = DownloadCache.shared

	nonisolated private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "Downloader")

	private init() {
		let sessionConfiguration = URLSessionConfiguration.ephemeral
		sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
		sessionConfiguration.httpShouldSetCookies = false
		sessionConfiguration.httpCookieAcceptPolicy = .never
		sessionConfiguration.httpMaximumConnectionsPerHost = 1
		sessionConfiguration.httpCookieStorage = nil

		if let userAgentHeaders = UserAgent.headers() {
			sessionConfiguration.httpAdditionalHeaders = userAgentHeaders
		}

		urlSession = URLSession(configuration: sessionConfiguration)
	}

	deinit {
		urlSession.invalidateAndCancel()
	}

	public func download(_ url: URL, userAgentStyle: UserAgentStyle = .feed, cachesResponse: Bool = true) async throws -> DownloadResponse {
		try await download(URLRequest(url: url), userAgentStyle: userAgentStyle, cachesResponse: cachesResponse)
	}

	public func download(_ urlRequest: URLRequest, userAgentStyle: UserAgentStyle = .feed, cachesResponse: Bool = true) async throws -> DownloadResponse {
		try await withCheckedThrowingContinuation { continuation in
			download(urlRequest, userAgentStyle: userAgentStyle, cachesResponse: cachesResponse) { downloadResponse, error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: downloadResponse)
				}
			}
		}
	}

	public func download(_ url: URL, userAgentStyle: UserAgentStyle = .feed, _ callback: @escaping DownloadCallback) {
		assert(Thread.isMainQueue)
		download(URLRequest(url: url), userAgentStyle: userAgentStyle, callback)
	}

	public func download(_ urlRequest: URLRequest, userAgentStyle: UserAgentStyle = .feed, cachesResponse: Bool = true, _ callback: @escaping DownloadCallback) {
		assert(Thread.isMainQueue)

		guard let url = urlRequest.url else {
			Self.logger.fault("Downloader: skipping download for URLRequest without a URL")
			return
		}

		guard url.isHTTPOrHTTPSURL() else {
			Self.logger.debug("Downloader: skipping download for non-http/https URL: \(url)")
			callback(DownloadResponse(data: nil, response: nil, returnedFromCache: false), nil)
			return
		}

		let isConditionalRequest = urlRequest.value(forHTTPHeaderField: HTTPRequestHeader.ifNoneMatch) != nil || urlRequest.value(forHTTPHeaderField: HTTPRequestHeader.ifModifiedSince) != nil
		let isCacheableRequest = urlRequest.httpMethod == HTTPMethod.get && !isConditionalRequest

		// Return cached record if available.
		if isCacheableRequest {
			if let cachedRecord = cache[url.absoluteString] {
				Self.logger.debug("Downloader: returning cached record for \(url)")
				callback(DownloadResponse(data: cachedRecord.data, response: cachedRecord.response, returnedFromCache: true), nil)
				return
			}
		}

		// Add callback. If there is already a download in progress for this URL, return early.
		if isConditionalRequest {
			Self.logger.debug("Downloader: downloading \(url) with conditional GET")
		} else if callbacks[url] == nil {
			Self.logger.debug("Downloader: downloading \(url)")
			callbacks[url] = [(callback, false)]
		} else {
			// A download is already in progress for this URL. Don’t start a separate download.
			// Add the callback to the callbacks array for this URL. This caller is coalesced
			// onto the in-progress download, so it makes no network request of its own.
			Self.logger.debug("Downloader: download in progress for \(url) — adding callback")
			callbacks[url]?.append((callback, true))
			return
		}

		var urlRequestToUse = urlRequest
		switch userAgentStyle {
		case .feed:
			break // the session's user agent
		case .specialCaseFeed:
			urlRequestToUse.setValue(UserAgent.extendedUserAgent, forHTTPHeaderField: HTTPRequestHeader.userAgent)
		case .browser:
			urlRequestToUse.setValue(UserAgent.browserUserAgent, forHTTPHeaderField: HTTPRequestHeader.userAgent)
		}
		urlRequestToUse.addSpecialCaseUserAgentIfNeeded() // Host requirements win over the requested style.

#if os(Windows)
		// WinHTTP, the system's HTTP stack, instead of swift-corelibs-foundation's URLSession. See WinHTTPClient.
		let additionalHeaders = UserAgent.headers()?.reduce(into: [String: String]()) { headers, header in
			if let field = header.key.base as? String {
				headers[field] = header.value
			}
		} ?? [:]
		let winHTTPRequest = urlRequestToUse
		Task.detached {
			var data: Data?
			var response: URLResponse?
			var error: Error?
			do {
				(data, response) = try await WinHTTPClient.shared.data(for: winHTTPRequest, additionalHeaders: additionalHeaders)
			} catch let downloadError {
				error = downloadError
			}
			await MainActor.run { [data, response, error] in
				self.downloadDidComplete(url, data: data, response: response, error: error, isCacheableRequest: isCacheableRequest, cachesResponse: cachesResponse, isConditionalRequest: isConditionalRequest, callback: callback)
			}
		}
#else
		let task = urlSession.dataTask(with: urlRequestToUse) { (data, response, error) in

			// Don’t cache errors — a retry should hit the network.
			if isCacheableRequest && cachesResponse && error == nil {
				Self.logger.debug("Downloader: caching response for \(url)")
				self.cache.add(url.absoluteString, data: data, response: response)
			}

			Task { @MainActor in
				if isConditionalRequest {
					callback(DownloadResponse(data: data, response: response, returnedFromCache: false), error)
				} else {
					self.callAndReleaseCallbacks(url, data, response, error)
				}
			}
		}
		task.resume()
#endif
	}
}

private extension Downloader {

#if os(Windows)
	/// As the URLSession completion handler does on other platforms.
	func downloadDidComplete(_ url: URL, data: Data?, response: URLResponse?, error: Error?, isCacheableRequest: Bool, cachesResponse: Bool, isConditionalRequest: Bool, callback: @escaping DownloadCallback) {
		// Don’t cache errors — a retry should hit the network.
		if isCacheableRequest && cachesResponse && error == nil {
			Self.logger.debug("Downloader: caching response for \(url)")
			cache.add(url.absoluteString, data: data, response: response)
		}
		if isConditionalRequest {
			callback(DownloadResponse(data: data, response: response, returnedFromCache: false), error)
		} else {
			callAndReleaseCallbacks(url, data, response, error)
		}
	}
#endif

	func callAndReleaseCallbacks(_ url: URL, _ data: Data? = nil, _ response: URLResponse? = nil, _ error: Error? = nil) {
		assert(Thread.isMainQueue)

		guard let callbacksForURL = callbacks[url] else {
			assertionFailure("Downloader: downloaded URL \(url) but no callbacks found")
			Self.logger.fault("Downloader: downloaded URL \(url) but no callbacks found")
			return
		}

		// Release before calling — a callback may start a new download of the same URL.
		callbacks[url] = nil

		let count = callbacksForURL.count
		if count == 1 {
			Self.logger.debug("Downloader: calling 1 callback for URL \(url)")
		} else {
			Self.logger.debug("Downloader: calling \(count) callbacks for URL \(url)")
		}

		for entry in callbacksForURL {
			let downloadResponse = DownloadResponse(data: data, response: response, returnedFromCache: entry.fromCache)
			entry.callback(downloadResponse, error)
		}
	}
}
