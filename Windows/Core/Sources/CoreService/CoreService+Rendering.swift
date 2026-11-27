//
//  CoreService+Rendering.swift
//  CoreService
//
//  The article page, rendered by the ArticleRendering module that Mac and iOS use,
//  in a Windows page template. The app loads it into WebView2 after injecting
//  `article.scripts` (main.js, newsfoot.js) and its own main_windows.js.
//

import Foundation
import RSCore
import Articles
import Account
import ArticleRendering

extension CoreService {

	/// The scheme `[[avatar_src]]` uses; the app answers it with the feed icon.
	nonisolated static let imageIconScheme = "nnwImageIcon"

	func renderArticle(_ params: RenderArticleParams) throws -> RenderedPage {
		guard let article = accountManager.fetchArticle(accountID: params.accountID, articleID: params.articleID) else {
			throw CoreServiceError.notFound("Article \(params.articleID)")
		}
		let rendering = ArticleHTMLRenderer.articleHTML(article: article, options: renderingOptions(textSize: params.textSize, themeName: params.themeName))
		return RenderedPage(rendering, windowScrollY: params.windowScrollY ?? 0)
	}

	func renderMessage(_ params: RenderMessageParams) -> RenderedPage {
		let rendering = ArticleHTMLRenderer.systemMessageHTML(params.message.escapingSpecialXMLCharacters, options: renderingOptions(textSize: nil, themeName: params.themeName))
		return RenderedPage(rendering, windowScrollY: 0)
	}

	func articleScripts() -> ArticleScripts {
		ArticleScripts(scripts: [ArticleRenderingResources.mainScript, ArticleRenderingResources.newsfootScript])
	}
}

// MARK: - Params and results

struct RenderArticleParams: Decodable {
	let accountID: String
	let articleID: String
	/// small, medium, large, xlarge, or xxlarge, as the Mac app's article text size setting.
	let textSize: ArticleTextSize?
	/// From `themes.list`. Nil, or a theme that's gone, means the default theme.
	let themeName: String?
	let windowScrollY: Int?
}

struct RenderMessageParams: Decodable {
	let message: String
	let themeName: String?
}

struct RenderedPage: Encodable {
	let html: String
	let title: String
	let baseURL: String

	@MainActor init(_ rendering: ArticleHTMLRenderer.Rendering, windowScrollY: Int) {
		self.html = ArticleHTMLRenderer.pageHTML(rendering, pageTemplate: CoreService.pageTemplate, windowScrollY: windowScrollY)
		self.title = rendering.title
		self.baseURL = rendering.baseURL
	}
}

struct ArticleScripts: Encodable {
	/// In order. Inject each before the page loads.
	let scripts: [String]
}

/// The Mac app's sizes (Shared/Article Rendering/ArticleTextSize.swift) and their CSS classes.
enum ArticleTextSize: String, Decodable {
	case small, medium, large, xlarge, xxlarge

	var cssClass: String {
		switch self {
		case .small:
			return "smallText"
		case .medium:
			return "mediumText"
		case .large:
			return "largeText"
		case .xlarge:
			return "xLargeText"
		case .xxlarge:
			return "xxLargeText"
		}
	}
}

// MARK: - Private

private extension CoreService {

	static let pageTemplate: String = {
		guard let url = Bundle.module.url(forResource: "page", withExtension: "html"), let template = try? String(contentsOf: url, encoding: .utf8) else {
			preconditionFailure("CoreService is missing its resource page.html")
		}
		return template
	}()

	func renderingOptions(textSize: ArticleTextSize?, themeName: String?) -> ArticleHTMLRenderer.Options {
		ArticleHTMLRenderer.Options(
			theme: themeName.flatMap { themeStore.theme(named: $0) } ?? .defaultTheme,
			textSizeClass: (textSize ?? .medium).cssClass,
			externalLinkLabel: "Link:",
			imageIconScheme: Self.imageIconScheme
		)
	}
}
