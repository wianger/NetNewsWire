//
//  URLSession+Webservice.swift
//  RSWeb
//
//  Created by Maurice Parker on 5/4/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RSCore
#if os(Windows)
import Synchronization
#endif

public enum WebserviceError: LocalizedError, Sendable {
	case noData
    case noURL
	case suspended
	case httpError(status: Int, responseBody: String?)
	case tooManyRequests(retryAfter: TimeInterval?)

	public var errorDescription: String? {
		switch self {
		case .httpError(let status, _):
			return "HTTP \(status): \(HTTPURLResponse.localizedString(forStatusCode: status))"
		case .noData:
			return NSLocalizedString("No data was returned by the server.", comment: "No data")
		case .noURL:
			return NSLocalizedString("The URL for the request is missing.", comment: "No URL")
		case .suspended:
			return NSLocalizedString("The request was not sent because syncing is suspended.", comment: "Suspended")
		case .tooManyRequests:
			return NSLocalizedString("The server reported too many requests. Syncing is paused temporarily.", comment: "Too many requests")
		}
	}

}

nonisolated extension URLSession {

	/// A session configured for web service calls. Each API caller owns its own session,
	/// so canceling one account’s requests can’t cancel another account’s.
	/// When running unit tests, it routes requests through `TestingURLProtocol`
	/// so no outside code needs any knowledge of testing.
	public static func makeWebserviceSession() -> URLSession {

		let sessionConfiguration = URLSessionConfiguration.default
		sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
		sessionConfiguration.timeoutIntervalForRequest = 60.0
		sessionConfiguration.timeoutIntervalForResource = 120.0
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

		if Platform.isRunningUnitTests {
			sessionConfiguration.protocolClasses = [TestingURLProtocol.self]

			// Stamp the session so the protocol can tell this test's requests from another's.
			if let testID = TestingURLProtocol.currentTestID {
				var headers = sessionConfiguration.httpAdditionalHeaders ?? [:]
				headers[TestingURLProtocol.testIDHeaderField] = testID
				sessionConfiguration.httpAdditionalHeaders = headers
			}
		}

		return URLSession(configuration: sessionConfiguration)
	}

	public func cancelAll() {
#if os(Windows)
		WinHTTPWebserviceTasks.shared.cancelAll(for: self)
#endif
		getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
			for task in dataTasks {
				task.cancel()
			}
			for task in uploadTasks {
				task.cancel()
			}
			for task in downloadTasks {
				task.cancel()
			}
		}
	}

	/// The request with the session's `httpAdditionalHeaders` added, request headers winning.
	/// Foundation on Apple platforms does this before a URLProtocol sees the request;
	/// swift-corelibs-foundation adds them only in its own HTTP layer, so a URLProtocol such as
	/// `TestingURLProtocol` would not see them. Send requests through this to get one behavior everywhere.
	public func requestWithAdditionalHeaders(_ request: URLRequest) -> URLRequest {
#if canImport(Darwin)
		return request
#else
		guard let additionalHeaders = configuration.httpAdditionalHeaders else {
			return request
		}
		var request = request
		for (key, value) in additionalHeaders {
			guard let field = key.base as? String, let value = value as? String, request.value(forHTTPHeaderField: field) == nil else {
				continue
			}
			request.setValue(value, forHTTPHeaderField: field)
		}
		return request
#endif
	}

	/// The response and body, whatever the status code. Prefer the `send` methods, which check it.
	public func webserviceData(for request: URLRequest) async throws -> (Data, URLResponse) {
#if os(Windows)
		if !Platform.isRunningUnitTests {
			return try await winHTTPData(for: request)
		}
#endif
		return try await data(for: requestWithAdditionalHeaders(request))
	}

	@discardableResult
	public func send(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
		let (data, response) = try await webserviceData(for: request)
		return (try Self.validatedHTTPResponse(response, data: data), data)
	}

	public func send(request: URLRequest, method: String) async throws {
		var sendRequest = request
		sendRequest.httpMethod = method
		let (data, response) = try await webserviceData(for: sendRequest)
		try Self.validatedHTTPResponse(response, data: data)
	}

	public func send(request: URLRequest, method: String, payload: Data) async throws -> (HTTPURLResponse, Data) {
		var sendRequest = request
		sendRequest.httpMethod = method
#if os(Windows)
		if !Platform.isRunningUnitTests {
			sendRequest.httpBody = payload
			let (data, response) = try await winHTTPData(for: sendRequest)
			return (try Self.validatedHTTPResponse(response, data: data), data)
		}
#endif
		let (data, response) = try await upload(for: requestWithAdditionalHeaders(sendRequest), from: payload)
		return (try Self.validatedHTTPResponse(response, data: data), data)
	}

	/// Require an HTTP response with a 200...399 status code, or throw the matching `WebserviceError`.
	@discardableResult
	private static func validatedHTTPResponse(_ response: URLResponse, data: Data?) throws -> HTTPURLResponse {
		guard let httpResponse = response as? HTTPURLResponse else {
			throw WebserviceError.noData
		}
		switch httpResponse.forcedStatusCode {
		case 200...399:
			return httpResponse
		case HTTPResponseCode.tooManyRequests:
			var retryAfter: TimeInterval?
			if let headerValue = httpResponse.value(forHTTPHeaderField: HTTPResponseHeader.retryAfter) {
				retryAfter = TimeInterval(headerValue)
			}
			throw WebserviceError.tooManyRequests(retryAfter: retryAfter)
		default:
			throw WebserviceError.httpError(status: httpResponse.forcedStatusCode, responseBody: responseBodyForError(data))
		}
	}

	/// A trimmed, whitespace-collapsed prefix of an error response's body.
	/// The body often says what the server didn't like.
	private static func responseBodyForError(_ data: Data?) -> String? {
		guard let data, !data.isEmpty, let body = String(data: data, encoding: .utf8) else {
			return nil
		}
		let collapsed = body.collapsingWhitespace
		guard !collapsed.isEmpty else {
			return nil
		}
		return String(collapsed.prefix(500))
	}
}

#if os(Windows)

// MARK: - Windows

/// On Windows, web service calls go through WinHTTP (see WinHTTPClient), with the session's
/// headers and timeouts. The session still owns them: cancelAll cancels them.
nonisolated extension URLSession {

	fileprivate func winHTTPData(for request: URLRequest) async throws -> (Data, URLResponse) {
		var additionalHeaders = [String: String]()
		for (key, value) in configuration.httpAdditionalHeaders ?? [:] {
			if let field = key.base as? String, let value = value as? String {
				additionalHeaders[field] = value
			}
		}
		let timeout = configuration.timeoutIntervalForRequest
		let resourceTimeout = configuration.timeoutIntervalForResource
		let task = Task {
			try await WinHTTPClient.shared.data(for: request, additionalHeaders: additionalHeaders, timeout: timeout, resourceTimeout: resourceTimeout)
		}
		let id = WinHTTPWebserviceTasks.shared.add(task, for: self)
		defer {
			WinHTTPWebserviceTasks.shared.remove(id, for: self)
		}
		let (data, response) = try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
		return (data, response)
	}
}

/// The web service requests in flight, by session, so `cancelAll` can cancel them.
final class WinHTTPWebserviceTasks: Sendable {

	static let shared = WinHTTPWebserviceTasks()

	private let tasks = Mutex([ObjectIdentifier: [UUID: Task<(Data, HTTPURLResponse), Error>]]())

	func add(_ task: Task<(Data, HTTPURLResponse), Error>, for session: URLSession) -> UUID {
		let id = UUID()
		tasks.withLock { $0[ObjectIdentifier(session), default: [:]][id] = task }
		return id
	}

	func remove(_ id: UUID, for session: URLSession) {
		tasks.withLock { tasks in
			tasks[ObjectIdentifier(session)]?[id] = nil
			if tasks[ObjectIdentifier(session)]?.isEmpty == true {
				tasks[ObjectIdentifier(session)] = nil
			}
		}
	}

	func cancelAll(for session: URLSession) {
		let sessionTasks = tasks.withLock { $0[ObjectIdentifier(session)].map { Array($0.values) } ?? [] }
		for task in sessionTasks {
			task.cancel()
		}
	}
}

#endif
