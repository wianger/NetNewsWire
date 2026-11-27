//
//  CoreService+Notifications.swift
//  CoreService
//
//  New-article notifications, as the Mac's UserNotificationManager decides them: for each new,
//  unread article from a feed whose notifications are on. The app shows them, and removes one
//  when its article is marked read (the articlesRead event).
//

import Foundation
import RSCore
import Articles
import Account

extension CoreService {

	func setFeedNotifications(_ params: FeedNotificationsParams) throws {
		let (_, feed) = try existingFeed(accountID: params.accountID, feedID: params.feedID)
		feed.newArticleNotificationsEnabled = params.enabled
	}

	func enqueueNewArticleNotices(_ articles: Set<Article>) {
		let notices = articles
			.filter { !$0.status.read }
			.compactMap { article -> NewArticleNotice? in
				guard let feed = article.feed, feed.newArticleNotificationsEnabled else {
					return nil
				}
				let title = article.title?.strippingHTML().collapsingWhitespace
				let summarySource = article.summary ?? article.contentHTML ?? article.contentText
				let summary = summarySource?.strippingHTML(maxCharacters: 200).collapsingWhitespace
				return NewArticleNotice(
					accountID: article.accountID,
					articleID: article.articleID,
					feedID: article.feedID,
					feedName: feed.nameForDisplay,
					title: title?.isEmpty == false ? title : nil,
					summary: summary?.isEmpty == false ? summary : nil
				)
			}
			.sorted { $0.articleID < $1.articleID }
		enqueueNewArticles(notices)
	}
}

struct FeedNotificationsParams: Decodable {
	let accountID: String
	let feedID: String
	let enabled: Bool
}
