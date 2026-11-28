//
//  ArticleSorter.swift
//  Articles
//
//  Created by Phil Viso on 9/8/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//
//  How timelines are sorted, on every platform. The apps supply the feed name
//  and the title as their timelines show them.
//

import Foundation

/// The field a timeline is sorted by. Raw values double as table column identifiers, sort descriptor keys, and menu item identifiers.
public enum ArticleSortKey: String, CaseIterable, Sendable {
	case date
	case feed
	case title
	case unread
	case starred

	/// Direction used the first time a field is chosen. Newest, unread, and starred go on top.
	public var sortsAscendingFirst: Bool {
		switch self {
		case .feed, .title:
			true
		case .date, .unread, .starred:
			false
		}
	}

	public var firstDirection: ComparisonResult {
		sortsAscendingFirst ? .orderedAscending : .orderedDescending
	}
}

/// How one timeline is sorted. Every field but date uses date, newest first, as the secondary sort.
public struct ArticleSortParameters: Equatable, Sendable {

	public let key: ArticleSortKey
	public let direction: ComparisonResult

	public static let newestFirst = ArticleSortParameters(key: .date, direction: .orderedDescending)

	public init(key: ArticleSortKey, direction: ComparisonResult) {
		self.key = key
		self.direction = direction
	}

	public func withDirection(_ direction: ComparisonResult) -> ArticleSortParameters {
		ArticleSortParameters(key: key, direction: direction)
	}
}

@MainActor public struct ArticleSorter {

	/// - Parameters:
	///   - feedNameFor: The feed name the timeline shows for an article.
	///   - titleFor: The text the timeline shows as an article's title.
	public static func sorted(articles: [Article], parameters: ArticleSortParameters, feedNameFor: (Article) -> String, titleFor: (Article) -> String) -> [Article] {
		switch parameters.key {
		case .date:
			sortedByDate(articles: articles, sortDirection: parameters.direction)
		case .feed:
			sortedByFeedName(articles: articles, sortDirection: .orderedDescending, feedNameDirection: parameters.direction, feedNameFor: feedNameFor)
		case .title:
			sortedByTitle(articles: articles, sortDirection: parameters.direction, titleFor: titleFor)
		case .unread:
			sortedByFlag(articles: articles, sortDirection: parameters.direction) { !$0.status.read }
		case .starred:
			sortedByFlag(articles: articles, sortDirection: parameters.direction) { $0.status.starred }
		}
	}

	public static func sortedByDate(articles: [Article], sortDirection: ComparisonResult, groupByFeed: Bool, feedNameFor: (Article) -> String) -> [Article] {
		if groupByFeed {
			sortedByFeedName(articles: articles, sortDirection: sortDirection, feedNameDirection: .orderedAscending, feedNameFor: feedNameFor)
		} else {
			sortedByDate(articles: articles, sortDirection: sortDirection)
		}
	}
}

// MARK: - Private

private extension ArticleSorter {

	static func sortedByFeedName(articles: [Article], sortDirection: ComparisonResult, feedNameDirection: ComparisonResult, feedNameFor: (Article) -> String) -> [Article] {
		// Group articles by feed ID so that two feeds with the same name remain in distinct groups.
		let groupedArticles = Dictionary(grouping: articles, by: \.feedID)
		let groupsWithNames = groupedArticles.map { (feedID: $0.key, name: feedNameFor($0.value[0]), articles: $0.value) }
		return groupsWithNames
			.sorted { lhs, rhs in
				switch lhs.name.localizedStandardCompare(rhs.name) {
				case .orderedAscending: feedNameDirection == .orderedAscending
				case .orderedDescending: feedNameDirection != .orderedAscending
				case .orderedSame: lhs.feedID < rhs.feedID
				}
			}
			.flatMap { sortedByDate(articles: $0.articles, sortDirection: sortDirection) }
	}

	static func sortedByDate(articles: [Article], sortDirection: ComparisonResult) -> [Article] {
		articles.sorted { article1, article2 in
			isOrderedByDate(article1, article2, sortDirection: sortDirection)
		}
	}

	static func sortedByTitle(articles: [Article], sortDirection: ComparisonResult, titleFor: (Article) -> String) -> [Article] {
		// Look up each title once instead of twice per comparison.
		let titledArticles = articles.map { (article: $0, title: titleFor($0)) }
		return titledArticles.sorted { item1, item2 in
			switch item1.title.localizedStandardCompare(item2.title) {
			case .orderedAscending: sortDirection == .orderedAscending
			case .orderedDescending: sortDirection != .orderedAscending
			case .orderedSame: isOrderedByDate(item1.article, item2.article, sortDirection: .orderedDescending)
			}
		}.map(\.article)
	}

	/// Descending puts articles with the flag set on top.
	static func sortedByFlag(articles: [Article], sortDirection: ComparisonResult, flag: (Article) -> Bool) -> [Article] {
		articles.sorted { article1, article2 in
			let flag1 = flag(article1)
			let flag2 = flag(article2)
			if flag1 == flag2 {
				return isOrderedByDate(article1, article2, sortDirection: .orderedDescending)
			}
			if sortDirection == .orderedDescending {
				return flag1
			}
			return flag2
		}
	}

	/// Ties on date are broken by articleID so the order is stable.
	static func isOrderedByDate(_ article1: Article, _ article2: Article, sortDirection: ComparisonResult) -> Bool {
		if article1.logicalDatePublished == article2.logicalDatePublished {
			article1.articleID < article2.articleID
		} else if sortDirection == .orderedDescending {
			article1.logicalDatePublished > article2.logicalDatePublished
		} else {
			article1.logicalDatePublished < article2.logicalDatePublished
		}
	}
}
