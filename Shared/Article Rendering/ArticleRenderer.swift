//
//  ArticleRenderer.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/8/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//
//  The app’s side of article rendering: the page files in the app bundle and the app’s
//  settings. The rendering itself is ArticleHTMLRenderer, in the ArticleRendering module,
//  which the Windows app shares.
//

import Foundation
#if os(iOS)
import UIKit
#endif
import RSCore
import Articles
import Account
import Images
import ArticleRendering

@MainActor struct ArticleRenderer {

	typealias Rendering = ArticleHTMLRenderer.Rendering

	struct Page {
		let url: URL
		let baseURL: URL
		let html: String

		init(name: String) {
			url = Bundle.main.url(forResource: name, withExtension: "html")!
			baseURL = url.deletingLastPathComponent()
			html = try! String(contentsOfFile: url.path, encoding: .utf8)
		}
	}

	static var imageIconScheme = "nnwImageIcon"
	/// Serves an image from the timeline’s copy. The percent-encoded original URL follows the scheme.
	static let articleImageScheme = "nnwArticleImage"

	static var blank = Page(name: "blank")
	static var page = Page(name: "page")

	// MARK: - API

	/// `routesThumbnailImages` points the thumbnail’s `<img>`s at `articleImageScheme`, which only a web view with `ArticleImageSchemeHandler` can load.
	static func articleHTML(article: Article, extractedArticle: ExtractedArticle? = nil, theme: ArticleTheme, routesThumbnailImages: Bool = false) -> Rendering {
		var options = options(theme: theme)
		options.extractedArticleContent = extractedArticle?.content
		options.extractedArticleURL = extractedArticle?.url
		if routesThumbnailImages, let thumbnailMode = AppDefaults.timelineThumbnailsDisplay.thumbnailMode, let thumbnailURL = ArticleThumbnailFinder.shared.thumbnailURL(for: article, mode: thumbnailMode) {
			options.thumbnailRouting = ArticleHTMLRenderer.ThumbnailRouting(thumbnailURL: thumbnailURL) { url in
				ArticleImageSchemeHandler.routedURLString(url)
			}
		}
		return ArticleHTMLRenderer.articleHTML(article: article, options: options)
	}

	static func multipleSelectionHTML(theme: ArticleTheme) -> Rendering {
		ArticleHTMLRenderer.systemMessageHTML("Multiple selection", options: options(theme: theme))
	}

	static func loadingHTML(theme: ArticleTheme) -> Rendering {
		ArticleHTMLRenderer.systemMessageHTML("Loading…", options: options(theme: theme))
	}

	static func noSelectionHTML(theme: ArticleTheme) -> Rendering {
		ArticleHTMLRenderer.systemMessageHTML("No selection", options: options(theme: theme))
	}

	static func noContentHTML(theme: ArticleTheme) -> Rendering {
		ArticleHTMLRenderer.systemMessageHTML("", options: options(theme: theme))
	}

	/// Full page HTML for a rendering, ready to load into a web view.
	static func pageHTML(_ rendering: Rendering, windowScrollY: Int) -> String {
		ArticleHTMLRenderer.pageHTML(rendering, pageTemplate: page.html, windowScrollY: windowScrollY)
	}
}

// MARK: - Private

private extension ArticleRenderer {

	static func options(theme: ArticleTheme) -> ArticleHTMLRenderer.Options {
		ArticleHTMLRenderer.Options(
			theme: theme,
			textSizeClass: textSizeClass,
			styleSubstitutions: styleSubstitutions(),
			externalLinkLabel: NSLocalizedString("Link:", comment: "Link"),
			imageIconScheme: imageIconScheme
		)
	}

	static var textSizeClass: String? {
		#if os(macOS)
		AppDefaults.articleTextSize.cssClass
		#else
		nil
		#endif
	}

	#if os(iOS)
	static func styleSubstitutions() -> [String: String] {
		var d = [String: String]()
		let bodyFont = UIFont.preferredFont(forTextStyle: .body)
		d["font-size"] = String(describing: bodyFont.pointSize)
		return d
	}
	#else
	static func styleSubstitutions() -> [String: String] {
		[String: String]()
	}
	#endif
}
