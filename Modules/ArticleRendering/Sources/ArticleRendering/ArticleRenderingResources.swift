//
//  ArticleRenderingResources.swift
//  ArticleRendering
//
//  The files every article page uses, from this module’s bundle:
//  the default theme (core.css, stylesheet.css, template.html) and the scripts
//  each platform’s web view loads before the page (main.js, newsfoot.js).
//

import Foundation

public enum ArticleRenderingResources {

	/// CSS every theme gets before its own stylesheet.
	public static let coreCSS = string("core", "css")

	/// The default theme’s stylesheet.
	public static let defaultStylesheet = string("stylesheet", "css")

	/// The default theme’s template.
	public static let defaultTemplate = string("template", "html")

	/// main.js: the article page behavior shared by every platform.
	public static let mainScript = string("main", "js")

	/// newsfoot.js: footnote popovers.
	public static let newsfootScript = string("newsfoot", "js")

	/// The default stylesheet as the renderer used it before themes: set off by newlines.
	static let defaultStylesheetWithNewlines = "\n\(defaultStylesheet)\n"
}

private extension ArticleRenderingResources {

	/// The module ships these files, so a missing one is a build error, not a runtime condition.
	static func string(_ name: String, _ fileExtension: String) -> String {
		guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension), let string = try? String(contentsOf: url, encoding: .utf8) else {
			preconditionFailure("ArticleRendering is missing its resource \(name).\(fileExtension)")
		}
		return string
	}
}
