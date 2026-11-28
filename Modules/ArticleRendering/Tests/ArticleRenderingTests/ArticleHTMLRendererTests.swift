//
//  ArticleHTMLRendererTests.swift
//  ArticleRenderingTests
//
//  The renderer end to end with the default theme: what a web view on any platform gets.
//

import Foundation
import Testing
import Articles
@testable import ArticleRendering

@MainActor @Suite struct ArticleHTMLRendererTests {

	@Test func defaultThemeRendersTitleBodyLinkAndDate() throws {
		let article = makeArticle(title: "Hello <b>World</b> <script>", contentHTML: "<p>The body.</p>", link: "https://example.com/post", externalLink: "https://other.example.com/source")

		var options = options()
		options.textSizeClass = "mediumText" // iOS leaves [[text_size_class]] unfilled, as before.
		let rendering = ArticleHTMLRenderer.articleHTML(article: article, options: options)

		#expect(rendering.title == "Hello <b>World</b> &lt;script&gt;")
		#expect(rendering.html.contains("<p>The body.</p>"))
		#expect(rendering.html.contains("https://example.com/post"))
		#expect(rendering.html.contains("Source:"), "the external link label comes from the app")
		#expect(rendering.html.contains("other.example.com/source"))
		#expect(rendering.html.contains("nnwImageIcon:"), "avatar_src uses the app's scheme")
		#expect(!rendering.html.contains("[["), "every macro is filled")
		#expect(rendering.style.contains(ArticleRenderingResources.coreCSS.prefix(40)))
	}

	@Test func plainTextBecomesParagraphs() {
		let article = makeArticle(title: "Plain", contentHTML: nil, contentText: "First line\n\nSecond line")
		let rendering = ArticleHTMLRenderer.articleHTML(article: article, options: options())
		#expect(rendering.html.contains("<p>First line</p>"))
		#expect(rendering.html.contains("<p>Second line</p>"))
	}

	@Test func textSizeClassIsFilledWhenGiven() {
		let article = makeArticle(title: "Sized", contentHTML: "<p>x</p>")
		var options = options()
		options.textSizeClass = "largeText"
		#expect(ArticleHTMLRenderer.articleHTML(article: article, options: options).html.contains("largeText"))
	}

	@Test func systemMessageAndPageTemplate() {
		let rendering = ArticleHTMLRenderer.systemMessageHTML("No selection", options: options())
		#expect(rendering.html == "<h3 class='systemMessage'>No selection</h3>")
		#expect(ArticleHTMLRenderer.systemMessageHTML("", options: options()).html.isEmpty)

		let page = ArticleHTMLRenderer.pageHTML(rendering, pageTemplate: "<title>[[title]]</title><style>[[style]]</style><base href=\"[[baseURL]]\">[[body]]", windowScrollY: 0)
		#expect(page.contains("<h3 class='systemMessage'>No selection</h3>"))
		#expect(page.contains("<style>"))
	}

	@Test func resourcesLoadFromTheModuleBundle() {
		#expect(ArticleRenderingResources.defaultTemplate.contains("[[body]]"))
		#expect(!ArticleRenderingResources.defaultStylesheet.isEmpty)
		#expect(ArticleRenderingResources.mainScript.contains("function"))
		#expect(!ArticleRenderingResources.newsfootScript.isEmpty)
		#expect(ArticleTheme.defaultTheme.template == ArticleRenderingResources.defaultTemplate)
	}
}

private extension ArticleHTMLRendererTests {

	func options() -> ArticleHTMLRenderer.Options {
		ArticleHTMLRenderer.Options(theme: .defaultTheme, externalLinkLabel: "Source:", imageIconScheme: "nnwImageIcon")
	}

	func makeArticle(title: String?, contentHTML: String?, contentText: String? = nil, link: String? = nil, externalLink: String? = nil) -> Article {
		let status = ArticleStatus(articleID: "a1", read: false, starred: false, dateArrived: Date(timeIntervalSince1970: 1_800_000_000))
		return Article(accountID: "test", articleID: "a1", feedID: "https://example.com/feed", uniqueID: "a1", title: title, contentHTML: contentHTML, contentText: contentText, markdown: nil, url: link, externalURL: externalLink, summary: nil, imageURL: nil, thumbnailURL: nil, datePublished: Date(timeIntervalSince1970: 1_800_000_000), dateModified: nil, authors: nil, attachments: nil, status: status)
	}
}
