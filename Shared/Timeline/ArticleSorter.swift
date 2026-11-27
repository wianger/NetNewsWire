//
//  ArticleSorter.swift
//  NetNewsWire
//
//  Created by Phil Viso on 9/8/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//
//  The sorting itself is in the Articles module, shared with Windows. These supply
//  the feed name and title as the Mac and iOS timelines show them.
//

import Foundation
import Articles

@MainActor extension ArticleSorter {

	static func sorted(articles: [Article], parameters: ArticleSortParameters, feedNameFor: (Article) -> String = { $0.sortableFeedName }) -> [Article] {
		sorted(articles: articles, parameters: parameters, feedNameFor: feedNameFor, titleFor: sortableTitle)
	}

	static func sortedByDate(articles: [Article], sortDirection: ComparisonResult, groupByFeed: Bool) -> [Article] {
		sortedByDate(articles: articles, sortDirection: sortDirection, groupByFeed: groupByFeed) { $0.sortableFeedName }
	}

	/// The text the timeline shows as the title: the title, or the start of the body for an untitled article.
	private static func sortableTitle(for article: Article) -> String {
		let title = ArticleStringFormatter.shared.truncatedTitle(article)
		if !title.isEmpty {
			return title
		}
		return ArticleStringFormatter.shared.truncatedSummary(article)
	}
}

// MARK: - Sorting

@MainActor extension Article {

	fileprivate var sortableFeedName: String {
		feed?.nameForDisplay ?? ""
	}
}
