//
//  ArticleStringFormatter.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 8/31/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import Articles
import RSCore
import RSParser
import ArticleRendering

@MainActor final class ArticleStringFormatter {

	static let shared = ArticleStringFormatter()

	private var feedNameCache = [String: String]()
	private var titleCache = [TitleCacheKey: String]()
	private var attributedTitleCache = [String: NSAttributedString]()
	private var summaryCache = [ArticleCacheKey: String]()

	private let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		return formatter
	}()

	private let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .none
		formatter.timeStyle = .short
		return formatter
	}()

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidGoToBackground(_:)), name: .appDidGoToBackground, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
	}

	func truncatedFeedName(_ feedName: String) -> String {
		if let cachedFeedName = feedNameCache[feedName] {
			return cachedFeedName
		}

		let maxFeedNameLength = 100

		// `utf8.count` is O(1); grapheme count <= utf8.count, so
		// this is a conservative-but-correct short-enough check.
		if feedName.utf8.count <= maxFeedNameLength {
			feedNameCache[feedName] = feedName
			return feedName
		}

		// Grapheme-safe truncation, bounded by `maxFeedNameLength`.
		let endIndex = feedName.index(feedName.startIndex, offsetBy: maxFeedNameLength, limitedBy: feedName.endIndex) ?? feedName.endIndex
		let s = String(feedName[..<endIndex])
		feedNameCache[feedName] = s
		return s
	}

	func truncatedTitle(_ article: Article, forHTML: Bool = false) -> String {
		guard let rawTitle = article.title, !rawTitle.isEmpty else {
			return ""
		}

		let cacheKey = TitleCacheKey(title: rawTitle, forHTML: forHTML)
		if let cachedTitle = titleCache[cacheKey] {
			return cachedTitle
		}

		guard let sanitized = Self.sanitizedTitle(rawTitle, forHTML: forHTML) else {
			return ""
		}

		// Replace with " " rather than "" so words don't
		// fuse (`"Part 1\nPart 2"` -> `"Part 1 Part 2"`).
		// The `collapsingWhitespace` call further down removes any doubles.
		var s = sanitized
		if s.rangeOfCharacter(from: Self.titleControlCharacters) != nil {
			s = s.replacingOccurrences(of: "\n", with: " ")
			s = s.replacingOccurrences(of: "\r", with: " ")
			s = s.replacingOccurrences(of: "\t", with: " ")
		}

		if !forHTML {
			s = s.decodingHTMLEntities()
		}

		s = s.collapsingWhitespace

		let maxLength = 1000

		if s.utf8.count <= maxLength {
			titleCache[cacheKey] = s
			return s
		}

		// Grapheme-safe truncation.
		let endIndex = s.index(s.startIndex, offsetBy: maxLength, limitedBy: s.endIndex) ?? s.endIndex
		s = String(s[..<endIndex])
		titleCache[cacheKey] = s
		return s
	}

	func attributedTruncatedTitle(_ article: Article) -> NSAttributedString {
		guard let rawTitle = article.title, !rawTitle.isEmpty else {
			return NSAttributedString()
		}

		if let cached = attributedTitleCache[rawTitle] {
			return cached
		}

		let title = truncatedTitle(article, forHTML: true)
		let attributed = NSAttributedString(simpleHTML: title)
		attributedTitleCache[rawTitle] = attributed
		return attributed
	}

	func truncatedSummary(_ article: Article) -> String {
		guard let body = article.body else {
			return ""
		}

		let key = ArticleCacheKey(articleID: article.articleID, accountID: article.accountID)
		if let cachedBody = summaryCache[key] {
			return cachedBody
		}

		// Strip first, then decode. Strip bounds the input to decode
		// at ~300 characters regardless of body size, and it
		// preserves author intent for entity-encoded tags like
		// `&lt;i&gt;` (decode-then-strip would misread those as
		// real `<i>` tags and drop the text).
		var s = body.strippingHTML(maxCharacters: 300)
		s = s.decodingHTMLEntities()
		if s == "Comments" { // Hacker News.
			s = ""
		}
		summaryCache[key] = s
		return s
	}

	// `dateString` is intentionally uncached: ~97% of dates are
	// unique at per-second precision in a real database, so a cache
	// is a net regression vs calling DateFormatter directly.
	func dateString(_ date: Date) -> String {
		if Calendar.dateIsToday(date) {
			return timeFormatter.string(from: date)
		}
		return dateFormatter.string(from: date)
	}

	/// The title with HTML sanitized. See `ArticleTitleSanitizer.sanitizedTitle(_:forHTML:)`,
	/// which the article renderer shares.
	nonisolated static func sanitizedTitle(_ title: String?, forHTML: Bool) -> String? {
		ArticleTitleSanitizer.sanitizedTitle(title, forHTML: forHTML)
	}
}

// MARK: - Private

private extension ArticleStringFormatter {

	// Article-identity key for the summary cache. Hashable struct
	// avoids per-lookup String allocation.
	struct ArticleCacheKey: Hashable {
		let articleID: String
		let accountID: String
	}

	// (raw title, forHTML) key. Hit path skips `sanitizedTitle`.
	// Including `forHTML` avoids a collision bug where tag-free
	// titles sanitized identically but produced different output
	// under the two flags.
	struct TitleCacheKey: Hashable {
		let title: String
		let forHTML: Bool
	}

	static let titleControlCharacters = CharacterSet(charactersIn: "\n\r\t")

	@objc func handleAppDidGoToBackground(_ notification: Notification) {
		emptyCaches()
	}

	@objc func handleLowMemory(_ notification: Notification) {
		emptyCaches()
	}

	func emptyCaches() {
		feedNameCache.removeAll()
		titleCache.removeAll()
		attributedTitleCache.removeAll()
		summaryCache.removeAll()
	}
}
