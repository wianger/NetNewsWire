//
//  WinHTTPClientTests.swift
//  RSWebTests
//
//  The rules WinHTTPClient applies itself: how a redirect is followed, how raw
//  headers become a response, and which URLError a WinHTTP error becomes.
//

#if os(Windows)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import WinSDK
import CWinHTTP
@testable import RSWeb

struct WinHTTPClientTests {

	// MARK: - Redirects

	@Test func permanentRedirectKeepsTheMethodAndBody() throws {
		var request = try makeRequest("https://example.com/feed", method: "PUT")
		request.httpBody = Data("body".utf8)
		let redirect = try #require(WinHTTPClient.redirectRequest(for: request, response: response(308, from: "https://example.com/feed", location: "/new-feed")))
		#expect(redirect.url?.absoluteString == "https://example.com/new-feed")
		#expect(redirect.httpMethod == "PUT")
		#expect(redirect.httpBody == Data("body".utf8))
	}

	@Test func seeOtherAndPostRedirectsBecomeGets() throws {
		for status in [301, 302, 303] {
			var request = try makeRequest("https://example.com/login", method: "POST")
			request.httpBody = Data("a=b".utf8)
			request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
			let redirect = try #require(WinHTTPClient.redirectRequest(for: request, response: response(status, from: "https://example.com/login", location: "https://example.com/home")))
			#expect(redirect.httpMethod == "GET", "status \(status)")
			#expect(redirect.httpBody == nil)
			#expect(redirect.value(forHTTPHeaderField: "Content-Type") == nil)
		}
	}

	@Test func authorizationIsNotSentToAnotherHost() throws {
		var request = try makeRequest("https://api.example.com/v2/entries")
		request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

		let sameHost = try #require(WinHTTPClient.redirectRequest(for: request, response: response(302, from: "https://api.example.com/v2/entries", location: "/v2/entries?page=2")))
		#expect(sameHost.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

		let otherHost = try #require(WinHTTPClient.redirectRequest(for: request, response: response(302, from: "https://api.example.com/v2/entries", location: "https://cdn.example.net/entries")))
		#expect(otherHost.value(forHTTPHeaderField: "Authorization") == nil)
	}

	@Test func nonRedirectsAndUnusableLocationsAreNotFollowed() throws {
		let request = try makeRequest("https://example.com/feed")
		#expect(WinHTTPClient.redirectRequest(for: request, response: try response(200, from: "https://example.com/feed", location: "/other")) == nil)
		#expect(WinHTTPClient.redirectRequest(for: request, response: try response(304, from: "https://example.com/feed", location: "/other")) == nil)
		#expect(WinHTTPClient.redirectRequest(for: request, response: try response(301, from: "https://example.com/feed", location: nil)) == nil)
		#expect(WinHTTPClient.redirectRequest(for: request, response: try response(301, from: "https://example.com/feed", location: "ftp://example.com/feed")) == nil)
	}

	// MARK: - Headers

	@Test func rawHeadersBecomeFieldsWithRepeatsJoined() {
		let raw = "HTTP/2 200 \r\ncontent-type: application/rss+xml\r\nETag: \"abc\"\r\nVary: Accept\r\nvary: Accept-Encoding\r\nX-Empty:\r\n\r\n"
		let (version, fields) = WinHTTPClient.parseRawHeaders(raw)
		#expect(version == "HTTP/2")
		#expect(fields["content-type"] == "application/rss+xml")
		#expect(fields["ETag"] == "\"abc\"")
		#expect(fields["Vary"] == "Accept, Accept-Encoding")
		#expect(fields["X-Empty"] == "")

		let url = URL(string: "https://example.com")
		let response = url.flatMap { HTTPURLResponse(url: $0, statusCode: 200, httpVersion: version, headerFields: fields) }
		#expect(response?.value(forHTTPHeaderField: "Content-Type") == "application/rss+xml")
	}

	// MARK: - Errors

	@Test func winHTTPErrorsBecomeURLSessionCodes() {
		let url = URL(string: "https://example.com/feed")
		let expected: [(Int64, URLError.Code)] = [
			(Int64(ERROR_WINHTTP_TIMEOUT), .timedOut),
			(Int64(ERROR_WINHTTP_NAME_NOT_RESOLVED), .cannotFindHost),
			(Int64(ERROR_WINHTTP_CANNOT_CONNECT), .cannotConnectToHost),
			(Int64(ERROR_WINHTTP_CONNECTION_ERROR), .networkConnectionLost),
			(Int64(ERROR_WINHTTP_SECURE_FAILURE), .secureConnectionFailed),
			(Int64(ERROR_WINHTTP_OPERATION_CANCELLED), .cancelled),
			(Int64(ERROR_WINHTTP_INVALID_SERVER_RESPONSE), .badServerResponse)
		]
		for (winHTTPError, code) in expected {
			let error = WinHTTPClient.urlError(DWORD(truncatingIfNeeded: winHTTPError), url: url)
			#expect(error.code == code, "WinHTTP error \(winHTTPError)")
			#expect(error.failingURL == url)
			#expect(!error.localizedDescription.contains("NSURLErrorDomain"), "WinHTTP error \(winHTTPError): \(error.localizedDescription)")
		}
		#expect(WinHTTPClient.urlError(DWORD(truncatingIfNeeded: ERROR_WINHTTP_INTERNAL_ERROR), url: url).code == .unknown)
	}
}

// MARK: - Helpers

private extension WinHTTPClientTests {

	func makeRequest(_ urlString: String, method: String = "GET") throws -> URLRequest {
		let url = try #require(URL(string: urlString))
		var request = URLRequest(url: url)
		request.httpMethod = method
		return request
	}

	func response(_ status: Int, from urlString: String, location: String?) throws -> HTTPURLResponse {
		let headers = location.map { ["Location": $0] } ?? [:]
		let url = try #require(URL(string: urlString))
		return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
	}
}

#endif
