//
//  WinHTTPClient.swift
//  RSWeb
//
//  The Windows HTTP transport. swift-corelibs-foundation's URLSession drives libcurl from a
//  libdispatch socket loop that spins a core for as long as a transfer runs (measured: 3.5 s of
//  CPU for a 4.6 s, 25 MB download, against 0.14 s for curl.exe), and doesn't use the system proxy.
//  WinHTTP is the system's HTTP stack: asynchronous completion callbacks, the user's proxy settings
//  (WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), Schannel and the Windows certificate store, HTTP/2 and,
//  where Windows supports it, HTTP/3.
//
//  Redirects are followed here rather than by WinHTTP, so callers can see each one, as
//  URLSession's willPerformHTTPRedirection delegate method lets DownloadSession do.
//

#if os(Windows)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import WinSDK
import CWinHTTP

/// Called as a request runs. Each is optional.
public struct WinHTTPHandlers: Sendable {

	/// Before following a redirect: the request to send instead, or nil to stop and return the redirect response.
	public var willRedirect: (@Sendable (_ response: HTTPURLResponse, _ newRequest: URLRequest) async -> URLRequest?)?

	/// Once the final response's headers arrive. False cancels the request.
	public var didReceiveResponse: (@Sendable (HTTPURLResponse) async -> Bool)?

	/// After each chunk of the body. False cancels the request.
	public var didReceiveData: (@Sendable (Data) async -> Bool)?

	public init(willRedirect: (@Sendable (HTTPURLResponse, URLRequest) async -> URLRequest?)? = nil, didReceiveResponse: (@Sendable (HTTPURLResponse) async -> Bool)? = nil, didReceiveData: (@Sendable (Data) async -> Bool)? = nil) {
		self.willRedirect = willRedirect
		self.didReceiveResponse = didReceiveResponse
		self.didReceiveData = didReceiveData
	}
}

public final class WinHTTPClient: @unchecked Sendable {

	/// One WinHTTP session for the app, so connections are pooled across feeds, images, and web services.
	public static let shared = WinHTTPClient()

	/// As URLSession allows by default.
	static let maximumRedirects = 16

	// Immutable after init; WinHTTP session handles are safe to use from any thread.
	private let session: HINTERNET?

	private init() {
		let userAgent = UserAgent.headers()?[AnyHashable(HTTPRequestHeader.userAgent)] ?? "NetNewsWire"
		session = userAgent.withCString(encodedAs: UTF16.self) { userAgentPointer in
			WinHttpOpen(userAgentPointer, DWORD(truncatingIfNeeded: WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, DWORD(truncatingIfNeeded: WINHTTP_FLAG_ASYNC))
		}
		guard let session else {
			return
		}

		// The completions the operations wait for, and handle closing, which releases them.
		let notifications = [WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE, WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE, WINHTTP_CALLBACK_STATUS_READ_COMPLETE, WINHTTP_CALLBACK_STATUS_REQUEST_ERROR, WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING]
			.reduce(DWORD(0)) { $0 | DWORD(truncatingIfNeeded: $1) }
		WinHttpSetStatusCallback(session, winHTTPStatusCallback, notifications, 0)

		// HTTP/3 needs a recent Windows; ask for both, and fall back to HTTP/2 alone.
		if !Self.setOption(session, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, DWORD(truncatingIfNeeded: WINHTTP_PROTOCOL_FLAG_HTTP2) | DWORD(truncatingIfNeeded: WINHTTP_PROTOCOL_FLAG_HTTP3)) {
			_ = Self.setOption(session, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, DWORD(truncatingIfNeeded: WINHTTP_PROTOCOL_FLAG_HTTP2))
		}
		// gzip and deflate, as URLSession on Apple platforms decodes them.
		_ = Self.setOption(session, WINHTTP_OPTION_DECOMPRESSION, DWORD(truncatingIfNeeded: WINHTTP_DECOMPRESSION_FLAG_ALL))
		// Redirects are followed in data(for:), so each can be seen.
		_ = Self.setOption(session, WINHTTP_OPTION_REDIRECT_POLICY, DWORD(truncatingIfNeeded: WINHTTP_OPTION_REDIRECT_POLICY_NEVER))
		// One connection per server, as every NetNewsWire URLSession is configured. HTTP/2 multiplexes on it.
		_ = Self.setOption(session, WINHTTP_OPTION_MAX_CONNS_PER_SERVER, 1)
		_ = Self.setOption(session, WINHTTP_OPTION_MAX_CONNS_PER_1_0_SERVER, 1)
	}

	/// Sends the request, following redirects, and returns the body and the final response.
	/// Errors are `URLError`s with the codes URLSession uses, so callers handle both alike.
	/// - Parameters:
	///   - additionalHeaders: Added unless the request has the same header, like URLSessionConfiguration.httpAdditionalHeaders.
	///   - timeout: Without data, how long to wait for each step. The request's timeoutInterval by default.
	///   - resourceTimeout: How long the whole request, redirects included, may take.
	@concurrent public func data(for request: URLRequest, additionalHeaders: [String: String] = [:], timeout: TimeInterval? = nil, resourceTimeout: TimeInterval? = nil, handlers: WinHTTPHandlers = WinHTTPHandlers()) async throws -> (Data, HTTPURLResponse) {
		guard let session else {
			throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "WinHTTP isn’t available."])
		}

		let deadline = Deadline()
		let deadlineTask: Task<Void, Never>? = resourceTimeout.map { resourceTimeout in
			Task {
				try? await Task.sleep(for: .seconds(resourceTimeout))
				if !Task.isCancelled {
					deadline.expire()
				}
			}
		}
		defer {
			deadlineTask?.cancel()
		}

		var currentRequest = request
		for _ in 0...Self.maximumRedirects {
			guard let url = currentRequest.url else {
				throw URLError(.badURL)
			}
			let operation = try WinHTTPOperation(session: session, request: currentRequest, additionalHeaders: additionalHeaders, timeout: timeout ?? currentRequest.timeoutInterval)
			defer {
				operation.close()
			}
			try deadline.start(operation)

			do {
				let response = try await operation.sendAndReceiveHeaders()

				if let redirect = Self.redirectRequest(for: currentRequest, response: response) {
					var followed: URLRequest? = redirect
					if let willRedirect = handlers.willRedirect {
						followed = await willRedirect(response, redirect)
					}
					guard let followed else {
						return (Data(), response) // The caller chose not to follow it.
					}
					currentRequest = followed
					continue
				}

				if let didReceiveResponse = handlers.didReceiveResponse, await !didReceiveResponse(response) {
					throw URLError(.cancelled, userInfo: [NSURLErrorFailingURLErrorKey: url])
				}

				var body = Data()
				while let chunk = try await operation.read() {
					body.append(chunk)
					if let didReceiveData = handlers.didReceiveData, await !didReceiveData(chunk) {
						throw URLError(.cancelled, userInfo: [NSURLErrorFailingURLErrorKey: url])
					}
				}
				return (body, response)
			} catch let error as URLError where error.code == .cancelled && deadline.isExpired {
				throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
			}
		}
		throw URLError(.httpTooManyRedirects, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any])
	}

	// MARK: - Redirects

	static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

	/// The request to send for a redirect response, as browsers and URLSession make it: 303, and 301 or 302
	/// after a POST, become a GET without a body. Authorization isn't sent on to another host. Nil if the
	/// response isn't a redirect, or has no usable Location.
	static func redirectRequest(for request: URLRequest, response: HTTPURLResponse) -> URLRequest? {
		guard redirectStatusCodes.contains(response.statusCode),
			  let location = response.value(forHTTPHeaderField: "Location"),
			  let currentURL = request.url,
			  let newURL = URL(string: location, relativeTo: currentURL)?.absoluteURL,
			  newURL.isHTTPOrHTTPSURL() else {
			return nil
		}

		var newRequest = request
		newRequest.url = newURL

		let method = request.httpMethod?.uppercased() ?? HTTPMethod.get
		if response.statusCode == 303 && method != "HEAD" || (response.statusCode == 301 || response.statusCode == 302) && method == HTTPMethod.post {
			newRequest.httpMethod = HTTPMethod.get
			newRequest.httpBody = nil
			newRequest.setValue(nil, forHTTPHeaderField: HTTPRequestHeader.contentType)
			newRequest.setValue(nil, forHTTPHeaderField: "Content-Length")
		}

		if newURL.host()?.lowercased() != currentURL.host()?.lowercased() {
			newRequest.setValue(nil, forHTTPHeaderField: HTTPRequestHeader.authorization)
		}
		return newRequest
	}

	// MARK: - Responses

	/// The HTTP version and header fields from WinHTTP's raw headers: the status line, then one header per line.
	/// Repeated headers are joined with commas, as HTTPURLResponse joins them.
	static func parseRawHeaders(_ rawHeaders: String) -> (httpVersion: String, fields: [String: String]) {
		var lines = rawHeaders.split(omittingEmptySubsequences: true) { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }
		guard !lines.isEmpty else {
			return ("HTTP/1.1", [:])
		}
		let statusLine = lines.removeFirst()
		let httpVersion = statusLine.split(separator: " ").first.map(String.init) ?? "HTTP/1.1"

		var fields = [String: String]()
		var canonicalNames = [String: String]() // lowercased → as first seen
		for line in lines {
			guard let colon = line.firstIndex(of: ":") else {
				continue
			}
			let name = line[..<colon].trimmingCharacters(in: .whitespaces)
			let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			guard !name.isEmpty else {
				continue
			}
			let key = canonicalNames[name.lowercased()] ?? name
			canonicalNames[name.lowercased()] = key
			if let existing = fields[key] {
				fields[key] = "\(existing), \(value)"
			} else {
				fields[key] = value
			}
		}
		return (httpVersion, fields)
	}

	/// The URLError for a WinHTTP or Win32 error, with the code URLSession would use.
	static func urlError(_ error: DWORD, url: URL?) -> URLError {
		let code: URLError.Code
		switch Int64(error) {
		case Int64(ERROR_WINHTTP_TIMEOUT):
			code = .timedOut
		case Int64(ERROR_WINHTTP_NAME_NOT_RESOLVED):
			code = .cannotFindHost
		case Int64(ERROR_WINHTTP_CANNOT_CONNECT):
			code = .cannotConnectToHost
		case Int64(ERROR_WINHTTP_CONNECTION_ERROR):
			code = .networkConnectionLost
		case Int64(ERROR_WINHTTP_OPERATION_CANCELLED):
			code = .cancelled
		case Int64(ERROR_WINHTTP_INVALID_URL), Int64(ERROR_WINHTTP_UNRECOGNIZED_SCHEME):
			code = .badURL
		case Int64(ERROR_WINHTTP_SECURE_FAILURE), Int64(ERROR_WINHTTP_SECURE_CERT_DATE_INVALID), Int64(ERROR_WINHTTP_SECURE_CERT_CN_INVALID),
			Int64(ERROR_WINHTTP_SECURE_INVALID_CA), Int64(ERROR_WINHTTP_SECURE_CERT_REV_FAILED), Int64(ERROR_WINHTTP_SECURE_CHANNEL_ERROR),
			Int64(ERROR_WINHTTP_SECURE_INVALID_CERT), Int64(ERROR_WINHTTP_SECURE_CERT_REVOKED), Int64(ERROR_WINHTTP_SECURE_CERT_WRONG_USAGE):
			code = .secureConnectionFailed
		case Int64(ERROR_WINHTTP_INVALID_SERVER_RESPONSE), Int64(ERROR_WINHTTP_HEADER_SIZE_OVERFLOW):
			code = .badServerResponse
		default:
			code = .unknown
		}
		var userInfo: [String: Any] = ["WinHTTPError": Int(error)]
		if let url {
			userInfo[NSURLErrorFailingURLErrorKey] = url
		}
		userInfo[NSLocalizedDescriptionKey] = localizedDescription(for: code) ?? "The network request failed (WinHTTP error \(error))."
		return URLError(code, userInfo: userInfo)
	}

	/// Apple's Foundation wording for these errors. swift-corelibs-foundation has none, so error messages
	/// would otherwise read “NSURLErrorDomain error -1004”.
	static func localizedDescription(for code: URLError.Code) -> String? {
		switch code {
		case .timedOut:
			return "The request timed out."
		case .cannotFindHost:
			return "A server with the specified hostname could not be found."
		case .cannotConnectToHost:
			return "Could not connect to the server."
		case .networkConnectionLost:
			return "The network connection was lost."
		case .cancelled:
			return "cancelled"
		case .badURL:
			return "unsupported URL"
		case .secureConnectionFailed:
			return "An SSL error has occurred and a secure connection to the server cannot be made."
		case .badServerResponse:
			return "The server returned a bad response."
		default:
			return nil
		}
	}

	@discardableResult
	static func setOption(_ handle: HINTERNET, _ option: some BinaryInteger, _ value: DWORD) -> Bool {
		var value = value
		return WinHttpSetOption(handle, DWORD(truncatingIfNeeded: option), &value, DWORD(MemoryLayout<DWORD>.size))
	}
}

// MARK: - Resource timeout

/// Cancels the operation in flight when the whole request has taken too long.
private final class Deadline: Sendable {

	private struct State {
		var isExpired = false
		var operation: WinHTTPOperation?
	}

	private let state = Mutex(State())

	var isExpired: Bool {
		state.withLock { $0.isExpired }
	}

	func start(_ operation: WinHTTPOperation) throws {
		let isExpired = state.withLock { state in
			state.operation = operation
			return state.isExpired
		}
		if isExpired {
			throw URLError(.timedOut)
		}
	}

	func expire() {
		let operation = state.withLock { state in
			state.isExpired = true
			return state.operation
		}
		operation?.cancel()
	}
}

// MARK: - One request

/// One WinHTTP request handle and its completions. WinHTTP calls back on its own threads;
/// each step stores a continuation that the callback resumes. Retained by its handle's
/// context value until WinHTTP reports the handle closing.
private final class WinHTTPOperation: @unchecked Sendable {

	private struct State {
		var connection: WinHTTPHandle?
		var request: WinHTTPHandle?
		var continuation: CheckedContinuation<Int, Error>?
		var isCancelled = false
	}

	private let state: Mutex<State>
	private let url: URL
	private let body: UnsafeMutableRawBufferPointer?
	private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)

	init(session: HINTERNET, request urlRequest: URLRequest, additionalHeaders: [String: String], timeout: TimeInterval) throws {
		guard let url = urlRequest.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: true), let host = components.host, !host.isEmpty else {
			throw URLError(.badURL)
		}
		let isSecure = components.scheme?.lowercased() == "https"
		guard isSecure || components.scheme?.lowercased() == "http" else {
			throw URLError(.unsupportedURL)
		}
		self.url = url

		if let httpBody = urlRequest.httpBody, !httpBody.isEmpty {
			let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: httpBody.count, alignment: 1)
			buffer.copyBytes(from: httpBody)
			body = buffer
		} else {
			body = nil
		}
		state = Mutex(State())

		let port = INTERNET_PORT(components.port ?? (isSecure ? 443 : 80))
		guard let connection = host.withCString(encodedAs: UTF16.self, { WinHttpConnect(session, $0, port, 0) }) else {
			throw WinHTTPClient.urlError(GetLastError(), url: url)
		}
		state.withLock { $0.connection = WinHTTPHandle(connection) }

		var object = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
		if let query = components.percentEncodedQuery {
			object += "?\(query)"
		}
		let method = urlRequest.httpMethod ?? HTTPMethod.get
		let request = method.withCString(encodedAs: UTF16.self) { methodPointer in
			object.withCString(encodedAs: UTF16.self) { objectPointer in
				WinHttpOpenRequest(connection, methodPointer, objectPointer, nil, nil, nil, isSecure ? DWORD(truncatingIfNeeded: WINHTTP_FLAG_SECURE) : 0)
			}
		}
		guard let request else {
			let error = GetLastError()
			WinHttpCloseHandle(connection)
			throw WinHTTPClient.urlError(error, url: url)
		}
		state.withLock { $0.request = WinHTTPHandle(request) }

		// No cookie handling: every NetNewsWire session turns cookies off. A request's own Cookie header is still sent.
		WinHTTPClient.setOption(request, WINHTTP_OPTION_DISABLE_FEATURE, DWORD(truncatingIfNeeded: WINHTTP_DISABLE_COOKIES))

		let milliseconds = Int32(clamping: Int((timeout > 0 ? timeout : 60) * 1000))
		WinHttpSetTimeouts(request, milliseconds, milliseconds, milliseconds, milliseconds)

		var headers = urlRequest.allHTTPHeaderFields ?? [:]
		for (name, value) in additionalHeaders where urlRequest.value(forHTTPHeaderField: name) == nil {
			headers[name] = value
		}
		// WinHTTP sets these itself: the length from the body, and the encodings it can decode.
		let managedHeaders: Set<String> = ["content-length", "accept-encoding", "host", "connection"]
		let headerBlock = headers
			.filter { !managedHeaders.contains($0.key.lowercased()) }
			.map { "\($0.key): \($0.value)\r\n" }
			.joined()
		if !headerBlock.isEmpty {
			let didAdd = headerBlock.withCString(encodedAs: UTF16.self) {
				WinHttpAddRequestHeaders(request, $0, DWORD.max, DWORD(truncatingIfNeeded: WINHTTP_ADDREQ_FLAG_ADD) | DWORD(truncatingIfNeeded: WINHTTP_ADDREQ_FLAG_REPLACE))
			}
			if !didAdd {
				let error = GetLastError()
				close() // No context yet, so nothing to release.
				throw WinHTTPClient.urlError(error, url: url)
			}
		}

		// Last, once nothing can fail: the context value is how callbacks find this object. Released when the handle closes.
		var context = DWORD_PTR(UInt(bitPattern: Unmanaged.passRetained(self).toOpaque()))
		WinHttpSetOption(request, DWORD(truncatingIfNeeded: WINHTTP_OPTION_CONTEXT_VALUE), &context, DWORD(MemoryLayout<DWORD_PTR>.size))
	}

	deinit {
		body?.deallocate()
		readBuffer.deallocate()
	}

	/// Sends the request and waits for the response headers.
	func sendAndReceiveHeaders() async throws -> HTTPURLResponse {
		let bodyLength = DWORD(body?.count ?? 0)
		let context = DWORD_PTR(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
		// SENDREQUEST_COMPLETE starts receiving; HEADERS_AVAILABLE resumes this.
		_ = try await perform { request in
			WinHttpSendRequest(request, nil, 0, self.body?.baseAddress, bodyLength, bodyLength, context)
		}
		return try response()
	}

	/// The next chunk of the body, or nil at its end.
	func read() async throws -> Data? {
		let count = try await perform { request in
			WinHttpReadData(request, self.readBuffer.baseAddress, DWORD(self.readBuffer.count), nil)
		}
		guard count > 0, let bytes = readBuffer.baseAddress else {
			return nil
		}
		return Data(bytes: bytes, count: count)
	}

	/// Ends the step in progress with a cancellation error, and closes the handles, which stops WinHTTP's work.
	func cancel() {
		let continuation = state.withLock { state in
			state.isCancelled = true
			defer {
				state.continuation = nil
			}
			return state.continuation
		}
		continuation?.resume(throwing: URLError(.cancelled, userInfo: [NSURLErrorFailingURLErrorKey: url]))
		close()
	}

	/// Closes the handles. Safe to call more than once.
	func close() {
		let (request, connection) = state.withLock { state in
			defer {
				state.request = nil
				state.connection = nil
			}
			return (state.request, state.connection)
		}
		if let request {
			WinHttpCloseHandle(request.handle)
		}
		if let connection {
			WinHttpCloseHandle(connection.handle)
		}
	}

	// MARK: Callbacks

	func sendRequestCompleted(_ request: HINTERNET) {
		if !WinHttpReceiveResponse(request, nil) {
			finish(.failure(WinHTTPClient.urlError(GetLastError(), url: url)))
		}
	}

	func finish(_ result: Result<Int, Error>) {
		let continuation = state.withLock { state in
			defer {
				state.continuation = nil
			}
			return state.continuation
		}
		continuation?.resume(with: result)
	}

	func failed(_ error: DWORD) {
		finish(.failure(WinHTTPClient.urlError(error, url: url)))
	}

	// MARK: Private

	/// Starts an asynchronous WinHTTP call and waits for the callback that completes it.
	private func perform(_ start: @escaping (HINTERNET) -> Bool) async throws -> Int {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let request: WinHTTPHandle? = state.withLock { state in
					guard !state.isCancelled, let request = state.request else {
						return nil
					}
					state.continuation = continuation
					return request
				}
				guard let request = request?.handle else {
					continuation.resume(throwing: URLError(.cancelled, userInfo: [NSURLErrorFailingURLErrorKey: url]))
					return
				}
				if !start(request) {
					failed(GetLastError())
				}
			}
		} onCancel: {
			cancel()
		}
	}

	private func response() throws -> HTTPURLResponse {
		guard let request = state.withLock({ $0.request })?.handle else {
			throw URLError(.cancelled, userInfo: [NSURLErrorFailingURLErrorKey: url])
		}

		var statusCode = DWORD(0)
		var statusSize = DWORD(MemoryLayout<DWORD>.size)
		guard WinHttpQueryHeaders(request, DWORD(truncatingIfNeeded: WINHTTP_QUERY_STATUS_CODE) | DWORD(truncatingIfNeeded: WINHTTP_QUERY_FLAG_NUMBER), nil, &statusCode, &statusSize, nil) else {
			throw WinHTTPClient.urlError(GetLastError(), url: url)
		}

		var size = DWORD(0)
		_ = WinHttpQueryHeaders(request, DWORD(truncatingIfNeeded: WINHTTP_QUERY_RAW_HEADERS_CRLF), nil, nil, &size, nil)
		var rawHeaders = ""
		if size > 0 {
			var buffer = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size + 1)
			if WinHttpQueryHeaders(request, DWORD(truncatingIfNeeded: WINHTTP_QUERY_RAW_HEADERS_CRLF), nil, &buffer, &size, nil) {
				rawHeaders = String(decoding: buffer.prefix(Int(size) / MemoryLayout<WCHAR>.size), as: UTF16.self)
			}
		}
		let (httpVersion, fields) = WinHTTPClient.parseRawHeaders(rawHeaders)
		guard let response = HTTPURLResponse(url: url, statusCode: Int(statusCode), httpVersion: httpVersion, headerFields: fields) else {
			throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
		}
		return response
	}
}

/// A WinHTTP handle. WinHTTP's handles can be used from any thread.
private struct WinHTTPHandle: @unchecked Sendable {
	let handle: HINTERNET

	init(_ handle: HINTERNET) {
		self.handle = handle
	}
}

/// WinHTTP's completion callback, for every request handle in the session.
private let winHTTPStatusCallback: WINHTTP_STATUS_CALLBACK = { handle, context, status, information, length in
	guard context != 0, let pointer = UnsafeMutableRawPointer(bitPattern: UInt(context)) else {
		return // The connection handles have no context.
	}
	let operation = Unmanaged<WinHTTPOperation>.fromOpaque(pointer)

	switch status {
	case DWORD(truncatingIfNeeded: WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE):
		if let handle {
			operation.takeUnretainedValue().sendRequestCompleted(handle)
		}
	case DWORD(truncatingIfNeeded: WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE):
		operation.takeUnretainedValue().finish(.success(0))
	case DWORD(truncatingIfNeeded: WINHTTP_CALLBACK_STATUS_READ_COMPLETE):
		operation.takeUnretainedValue().finish(.success(Int(length)))
	case DWORD(truncatingIfNeeded: WINHTTP_CALLBACK_STATUS_REQUEST_ERROR):
		let error = information?.assumingMemoryBound(to: WINHTTP_ASYNC_RESULT.self).pointee.dwError ?? DWORD(truncatingIfNeeded: ERROR_WINHTTP_INTERNAL_ERROR)
		operation.takeUnretainedValue().failed(error)
	case DWORD(truncatingIfNeeded: WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING):
		operation.release() // The retain from init.
	default:
		break
	}
}

#endif
