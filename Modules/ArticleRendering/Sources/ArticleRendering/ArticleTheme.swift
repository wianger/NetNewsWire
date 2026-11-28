//
//  ArticleTheme.swift
//  ArticleRendering
//
//  Created by Brent Simmons on 9/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation

public struct ArticleTheme: Equatable, Sendable {

	public static let defaultTheme = ArticleTheme()
	public static let nnwThemeSuffix = ".nnwtheme"

	private static let defaultThemeName = NSLocalizedString("Default", comment: "Default")
	private static let unknownValue = NSLocalizedString("Unknown", comment: "Unknown Value")

	/// Used instead of template.html when present. Older versions of NetNewsWire ignore it,
	/// so a theme can use the 7.3 tags here and keep template.html free of them.
	private static let template7_3Filename = "template7.3.html"
	private static let templateFilename = "template.html"

	public let url: URL?
	public let template: String?
	public let css: String?
	public let isAppTheme: Bool

	public var name: String {
		guard let url else { return Self.defaultThemeName }
		return Self.themeNameForPath(url.path)
	}

	public var creatorHomePage: String {
		return info?.creatorHomePage ?? Self.unknownValue
	}

	public var creatorName: String {
		return info?.creatorName ?? Self.unknownValue
	}

	public var version: String {
		return String(describing: info?.version ?? 0)
	}

	public var usesGrayscaleIcon: Bool {
		info?.grayscaleIcon ?? false
	}

	private let info: ArticleThemePlist?

	public init() {
		self.url = nil
		self.info = ArticleThemePlist(name: "Article Theme", themeIdentifier: "com.ranchero.netnewswire.theme.article", creatorHomePage: "https://netnewswire.com/", creatorName: "Ranchero Software", version: 1, grayscaleIcon: nil)

		self.css = ArticleRenderingResources.coreCSS + "\n" + ArticleRenderingResources.defaultStylesheet
		self.template = ArticleRenderingResources.defaultTemplate

		self.isAppTheme = true
	}

	public init(url: URL, isAppTheme: Bool) throws {
#if canImport(Darwin)
		_ = url.startAccessingSecurityScopedResource()
		defer {
			url.stopAccessingSecurityScopedResource()
		}
#endif

		self.url = url

		let styleSheetURL = url.appendingPathComponent("stylesheet.css")
		if let stylesheetCSS = Self.stringAtPath(styleSheetURL.path) {
			self.css = ArticleRenderingResources.coreCSS + "\n" + stylesheetCSS
		} else {
			self.css = nil
		}

		let template7_3URL = url.appendingPathComponent(Self.template7_3Filename)
		let templateURL = url.appendingPathComponent(Self.templateFilename)
		self.template = Self.stringAtPath(template7_3URL.path) ?? Self.stringAtPath(templateURL.path)

		self.isAppTheme = isAppTheme

		let infoURL = url.appendingPathComponent("Info.plist")
		let data = try Data(contentsOf: infoURL)
		self.info = try PropertyListDecoder().decode(ArticleThemePlist.self, from: data)
	}

	public static func stringAtPath(_ f: String) -> String? {
		if !FileManager.default.fileExists(atPath: f) {
			return nil
		}

		var encoding = String.Encoding.utf8
		if let s = try? String(contentsOfFile: f, usedEncoding: &encoding) {
			return s
		}
		return nil
	}

	public static func filenameWithThemeSuffixRemoved(_ filename: String) -> String {
		return filename.stripping(suffix: Self.nnwThemeSuffix)
	}

	public static func themeNameForPath(_ f: String) -> String {
		let filename = (f as NSString).lastPathComponent
		return filenameWithThemeSuffixRemoved(filename)
	}

	public static func pathIsPathForThemeName(_ themeName: String, path: String) -> Bool {
		let filename = (path as NSString).lastPathComponent
		return filenameWithThemeSuffixRemoved(filename) == themeName
	}
}
