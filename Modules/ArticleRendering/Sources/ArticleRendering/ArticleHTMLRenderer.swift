//
//  ArticleHTMLRenderer.swift
//  ArticleRendering
//
//  Created by Brent Simmons on 9/8/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//
//  Fills a theme’s template with an article. Moved from the app’s ArticleRenderer, which is now
//  a thin adapter that passes in app settings, so Mac, iOS, and Windows render articles the same way.
//

import Foundation
import RSCore
import RSParser
import Articles
import Account

@MainActor public struct ArticleHTMLRenderer {

	/// The theme’s CSS, the article HTML, the title, and the base URL — what a page template needs.
	public typealias Rendering = (style: String, html: String, title: String, baseURL: String)

	/// What the app decides; the renderer itself has no settings.
	public struct Options {
		public var theme: ArticleTheme
		/// Reader view: the extracted article’s content and URL replace the feed’s content.
		public var extractedArticleContent: String?
		public var extractedArticleURL: String?
		/// The `[[text_size_class]]` CSS class. Nil leaves it unset, as on iOS.
		public var textSizeClass: String?
		/// Substitutions into the theme’s CSS, such as iOS’s `[[font-size]]`.
		public var styleSubstitutions: [String: String]
		/// `[[external_link_label]]`, localized by the app.
		public var externalLinkLabel: String
		/// The scheme of `[[avatar_src]]`, which the app’s web view answers with the feed icon.
		public var imageIconScheme: String
		/// Points the `<img>`s showing the timeline thumbnail at a URL the web view serves from
		/// the timeline’s copy. Nil to leave image URLs alone.
		public var thumbnailRouting: ThumbnailRouting?

		public init(theme: ArticleTheme, extractedArticleContent: String? = nil, extractedArticleURL: String? = nil, textSizeClass: String? = nil, styleSubstitutions: [String: String] = [:], externalLinkLabel: String = "Link:", imageIconScheme: String, thumbnailRouting: ThumbnailRouting? = nil) {
			self.theme = theme
			self.extractedArticleContent = extractedArticleContent
			self.extractedArticleURL = extractedArticleURL
			self.textSizeClass = textSizeClass
			self.styleSubstitutions = styleSubstitutions
			self.externalLinkLabel = externalLinkLabel
			self.imageIconScheme = imageIconScheme
			self.thumbnailRouting = thumbnailRouting
		}
	}

	public struct ThumbnailRouting {
		/// The thumbnail’s original URL, as the timeline shows it.
		public let thumbnailURL: String
		/// The URL to load it from instead, or nil to leave it alone.
		public let routedURLString: (String) -> String?

		public init(thumbnailURL: String, routedURLString: @escaping (String) -> String?) {
			self.thumbnailURL = thumbnailURL
			self.routedURLString = routedURLString
		}
	}

	private let article: Article?
	private let options: Options
	private let title: String
	private let body: String
	private let baseURL: URL?

	private static let primaryMediaKey = "primary_media"
	private static let primaryMediaMacro = "[[primary_media]]"
	private static let enclosuresKey = "enclosures"
	private static let enclosuresMacro = "[[enclosures]]"

	private static func dateFormatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
		let formatter = DateFormatter()
		formatter.dateStyle = date
		formatter.timeStyle = time
		return formatter
	}

	private static let longDateTimeFormatter = dateFormatter(date: .long, time: .medium)
	private static let mediumDateTimeFormatter = dateFormatter(date: .medium, time: .short)
	private static let shortDateTimeFormatter = dateFormatter(date: .short, time: .short)
	private static let longDateFormatter = dateFormatter(date: .long, time: .none)
	private static let mediumDateFormatter = dateFormatter(date: .medium, time: .none)
	private static let shortDateFormatter = dateFormatter(date: .short, time: .none)
	private static let longTimeFormatter = dateFormatter(date: .none, time: .long)
	private static let mediumTimeFormatter = dateFormatter(date: .none, time: .medium)
	private static let shortTimeFormatter = dateFormatter(date: .none, time: .short)

	private init(article: Article?, options: Options) {
		self.article = article
		self.options = options
		self.title = ArticleTitleSanitizer.sanitizedTitle(article?.title, forHTML: true) ?? ""

		var articleBody: String
		var baseURL: URL?
		if let content = options.extractedArticleContent {
			articleBody = ArticleRenderingSpecialCases.extractBodyFragmentIfNeeded(content)
			if let extractedArticleURL = options.extractedArticleURL {
				baseURL = URL(string: extractedArticleURL)
			}
		} else {
			let feedURL = article?.feed?.url
			let homePageURL = article?.feed?.homePageURL

			articleBody = ArticleRenderingSpecialCases.extractBodyFragmentIfNeeded(Self.bodyHTML(article))
			articleBody = ArticleRenderingSpecialCases.insertParagraphTagsIfNeeded(articleBody, feedURL: feedURL, homePageURL: homePageURL)
			articleBody = ArticleRenderingSpecialCases.removeStrayLineBreaksIfNeeded(articleBody, feedURL: feedURL, homePageURL: homePageURL)
			articleBody = ArticleRenderingSpecialCases.enlargeFlickrImagesIfNeeded(articleBody, feedURL: feedURL, attachmentURLs: article?.attachments?.map { $0.url } ?? [])
			if article?.account?.type == .freshRSS {
				articleBody = ArticleRenderingSpecialCases.desanitizeFreshRSSContent(articleBody)
			}

			if let articleBaseURL = article?.baseURL {
				baseURL = ArticleRenderingSpecialCases.baseURLForRendering(articleBaseURL)
			}
		}

		self.body = articleBody
		self.baseURL = baseURL
	}

	// MARK: - API

	public static func articleHTML(article: Article, options: Options) -> Rendering {
		let renderer = ArticleHTMLRenderer(article: article, options: options)
		return (renderer.articleCSS, renderer.articleHTML, renderer.title, renderer.baseURL?.absoluteString ?? "")
	}

	/// A page with a message in place of an article, such as “No selection”.
	public static func systemMessageHTML(_ message: String, options: Options) -> Rendering {
		let renderer = ArticleHTMLRenderer(article: nil, options: options)
		let html = message.isEmpty ? "" : "<h3 class='systemMessage'>\(message)</h3>"
		return (renderer.articleCSS, html, renderer.title, renderer.baseURL?.absoluteString ?? "")
	}

	/// The page template with a rendering filled in, ready for a web view.
	public static func pageHTML(_ rendering: Rendering, pageTemplate: String, windowScrollY: Int) -> String {
		let substitutions = [
			"title": rendering.title,
			"baseURL": rendering.baseURL,
			"style": rendering.style,
			"body": rendering.html,
			"windowScrollY": String(windowScrollY)
		]

		let html = (try? MacroProcessor.renderedText(withTemplate: pageTemplate, substitutions: substitutions)) ?? ""
		return ArticleRenderingSpecialCases.filterHTMLIfNeeded(baseURL: rendering.baseURL, html: html)
	}
}

// MARK: - Private

private extension ArticleHTMLRenderer {

	/// The article’s body as HTML. Plain text (`contentText`, used when there’s no `contentHTML`) gets converted.
	static func bodyHTML(_ article: Article?) -> String {
		guard let article else {
			return ""
		}
		if article.contentHTML == nil, let contentText = article.contentText {
			return contentText.convertingPlainTextToHTML
		}
		return article.body ?? ""
	}

	var articleHTML: String {
		(try? MacroProcessor.renderedText(withTemplate: template, substitutions: articleSubstitutions())) ?? ""
	}

	var articleCSS: String {
		(try? MacroProcessor.renderedText(withTemplate: styleString, substitutions: options.styleSubstitutions)) ?? ""
	}

	var styleString: String {
		options.theme.css ?? ArticleRenderingResources.defaultStylesheetWithNewlines
	}

	var template: String {
		options.theme.template ?? ArticleRenderingResources.defaultTemplate
	}

	func articleSubstitutions() -> [String: String] {
		var d = [String: String]()

		guard let article else {
			assertionFailure("Article should have been set before calling this function.")
			return d
		}

		d["title"] = title
		d["preferred_link"] = article.preferredLink ?? ""

		if let externalLink = article.externalLink, externalLink != article.preferredLink {
			d["external_link_label"] = options.externalLinkLabel
			d["external_link_stripped"] = externalLink.strippingHTTPOrHTTPSScheme
			d["external_link"] = externalLink
		} else {
			d["external_link_label"] = ""
			d["external_link_stripped"] = ""
			d["external_link"] = ""
		}

		// Templates without [[primary_media]], and short untitled posts, get the article image in the enclosures.
		// The thumbnail is used only for [[primary_media]].
		let bodyImageIdentities = Self.bodyImageIdentities(body, baseURL: baseURL)
		var attachments = article.attachments ?? []
		var primaryMediaHTML = ""
		var primaryMediaURLs = Set<String>()
		let hasPrimaryMedia = template.contains(Self.primaryMediaMacro)
		let showsPrimaryImage = hasPrimaryMedia && !Self.isShortUntitledPost(title: article.title, body: body)
		if hasPrimaryMedia, let primaryMedia = Self.primaryMedia(imageLink: article.imageLink, thumbnailLink: article.thumbnailLink, attachments: attachments, articleTitle: article.title, body: body, bodyImageIdentities: bodyImageIdentities, includesImage: showsPrimaryImage) {
			primaryMediaHTML = primaryMedia.html
			primaryMediaURLs = primaryMedia.attachmentURLs
			attachments.removeAll { primaryMediaURLs.contains($0.url) }
		}
		if !showsPrimaryImage, let primaryImage = Self.primaryImage(imageLink: article.imageLink, thumbnailLink: nil, attachments: attachments, body: body, bodyImageIdentities: bodyImageIdentities), !primaryMediaURLs.contains(primaryImage.url), !attachments.contains(primaryImage) {
			attachments.insert(primaryImage, at: 0)
		}

		// Templates without [[enclosures]] get them at the end of the body.
		var enclosures = Self.enclosuresHTML(attachments: attachments, body: body, bodyImageIdentities: bodyImageIdentities, posterURL: article.imageLink ?? article.thumbnailLink)
		var body = body
		if let thumbnailRouting = options.thumbnailRouting {
			body = Self.routingThumbnailImages(body, routing: thumbnailRouting, baseURL: baseURL)
			enclosures = Self.routingThumbnailImages(enclosures, routing: thumbnailRouting, baseURL: baseURL)
			primaryMediaHTML = Self.routingThumbnailImages(primaryMediaHTML, routing: thumbnailRouting, baseURL: baseURL)
		}
		d[Self.primaryMediaKey] = primaryMediaHTML
		if template.contains(Self.enclosuresMacro) {
			d["body"] = body
			d[Self.enclosuresKey] = enclosures
		} else if enclosures.isEmpty {
			d["body"] = body
		} else {
			// The wrapper div closes anything the body leaves open, such as an unclosed
			// <audio> (Micro.blog posts have them), so the enclosures can’t end up inside it.
			d["body"] = "<div>" + body + "</div>" + enclosures
		}

		if let textSizeClass = options.textSizeClass {
			d["text_size_class"] = textSizeClass
		}

		var components = URLComponents()
		components.scheme = options.imageIconScheme
		components.path = article.articleID
		d["avatar_src"] = components.string ?? ""

		d["dateline_style"] = title.isEmpty ? "articleDatelineTitle" : "articleDateline"

		d["feed_link_title"] = article.feed?.nameForDisplay ?? ""
		d["feed_link"] = article.feed?.homePageURL ?? ""

		d["byline"] = byline()

		let datePublished = article.logicalDatePublished
		d["datetime_long"] = Self.longDateTimeFormatter.string(from: datePublished)
		d["datetime_medium"] = Self.mediumDateTimeFormatter.string(from: datePublished)
		d["datetime_short"] = Self.shortDateTimeFormatter.string(from: datePublished)
		d["date_long"] = Self.longDateFormatter.string(from: datePublished)
		d["date_medium"] = Self.mediumDateFormatter.string(from: datePublished)
		d["date_short"] = Self.shortDateFormatter.string(from: datePublished)
		d["time_long"] = Self.longTimeFormatter.string(from: datePublished)
		d["time_medium"] = Self.mediumTimeFormatter.string(from: datePublished)
		d["time_short"] = Self.shortTimeFormatter.string(from: datePublished)

		return d
	}

	/// Points the `<img>`s that show the article’s timeline thumbnail at the routed URL,
	/// so the article view uses the timeline’s copy instead of downloading the image again.
	/// `data-nnw-src` keeps the original URL, which main.js falls back to when the copy can’t be loaded.
	static func routingThumbnailImages(_ html: String, routing: ThumbnailRouting, baseURL: URL?) -> String {
		guard let routedURLString = routing.routedURLString(routing.thumbnailURL) else {
			return html
		}
		let attributes = " src=\"\(routedURLString)\" data-nnw-src=\"\(routing.thumbnailURL.escapingSpecialXMLCharacters)\""
		return HTMLImageAttributeInserter.insertingAttributes(attributes, intoImagesWithSource: routing.thumbnailURL, html: html, baseURL: baseURL)
	}

	func byline() -> String {
		guard let authors = article?.authors ?? article?.feed?.authors, !authors.isEmpty else {
			return ""
		}

		// If the author's name is the same as the feed, then we don't want to display it.
		// This code assumes that multiple authors would never match the feed name so that
		// if there feed owner has an article co-author all authors are given the byline.
		if authors.count == 1, let author = authors.first {
			if author.name == article?.feed?.nameForDisplay {
				return ""
			}
		}

		var byline = ""
		var isFirstAuthor = true

		for author in authors {
			if !isFirstAuthor {
				byline += ", "
			}
			isFirstAuthor = false

			var authorEmailAddress: String?
			if let emailAddress = author.emailAddress, !(emailAddress.contains("noreply@") || emailAddress.contains("no-reply@")) {
				authorEmailAddress = emailAddress
			}

			if let emailAddress = authorEmailAddress, emailAddress.contains(" ") {
				byline += emailAddress // probably name plus email address
			} else if let name = author.name, let url = author.url {
				byline += name.htmlByAddingLink(url)
			} else if let name = author.name, let emailAddress = authorEmailAddress {
				byline += "\(name) &lt;\(emailAddress)&gt;"
			} else if let name = author.name {
				byline += name
			} else if let emailAddress = authorEmailAddress {
				byline += "&lt;\(emailAddress)&gt;" // TODO: mailto link
			} else if let url = author.url {
				byline += String.htmlWithLink(url)
			}
		}

		return byline
	}
}
