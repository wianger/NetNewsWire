//
//  CoreService+Themes.swift
//  CoreService
//
//  Article themes, as the Mac's ArticleThemesManager finds them: the default theme, the
//  .nnwtheme folders that ship with the app (Themes/ in the repository, next to the exe on
//  Windows), and the ones the user installed in the data folder's Themes folder.
//

import Foundation
import RSCore
import ArticleRendering
import RSWeb
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension CoreService {

	func listThemes() -> [ThemeInfo] {
		themeStore.themeNames().compactMap { name in
			guard let theme = themeStore.theme(named: name) else {
				return nil
			}
			return ThemeInfo(name: name, creatorName: theme.creatorName, creatorHomePage: theme.creatorHomePage, version: theme.version, isAppTheme: theme.isAppTheme, isDefault: theme.url == nil)
		}
	}

	/// Copies a .nnwtheme folder into the installed themes, replacing one with the same name.
	func installTheme(_ params: InstallThemeParams) throws -> ThemeInfo {
		let source = URL(filePath: params.path, directoryHint: .isDirectory)
		guard source.pathExtension.lowercased() == "nnwtheme" else {
			throw CoreServiceError.invalidParams("A theme is a folder whose name ends in .nnwtheme.")
		}
		// Load it first, so a broken theme isn't installed.
		let theme: ArticleTheme
		do {
			theme = try ArticleTheme(url: source, isAppTheme: false)
		} catch {
			throw CoreServiceError(code: "invalidTheme", message: "This theme can’t be used: \(error.localizedDescription)")
		}
		let destination = themeStore.installedThemesFolder.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
		if FileManager.default.fileExists(atPath: destination.path) {
			try FileManager.default.removeItem(at: destination)
		}
		try FileManager.default.copyItem(at: source, to: destination)
		themeStore.emptyCache()
		return ThemeInfo(name: theme.name, creatorName: theme.creatorName, creatorHomePage: theme.creatorHomePage, version: theme.version, isAppTheme: false, isDefault: false)
	}

	/// Downloads a theme's zip archive from a netnewswire://theme/ link, as the Mac's ArticleThemeDownloader
	/// does: http or https only, at most 10 MB, with a browser user agent. Returns where the zip was saved;
	/// the app unzips it and asks before installing.
	func downloadTheme(_ params: ThemeURLParams) async throws -> DownloadedTheme {
		guard let url = URL(string: params.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			throw CoreServiceError.invalidParams("A NetNewsWire theme can be downloaded only from an http or https URL.")
		}
		let response: DownloadResponse
		do {
			response = try await Downloader.shared.download(url, userAgentStyle: .browser, cachesResponse: false)
		} catch {
			throw CoreServiceError(code: "failed", message: "The NetNewsWire theme could not be downloaded: \(error.localizedDescription)")
		}
		guard let data = response.data, !data.isEmpty, let httpResponse = response.response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
			throw CoreServiceError(code: "failed", message: "The NetNewsWire theme could not be downloaded.")
		}
		guard data.count <= Self.maximumThemeDownloadSize else {
			throw CoreServiceError(code: "failed", message: "The NetNewsWire theme is too large.")
		}
		let zip = FileManager.default.temporaryDirectory.appending(path: "NetNewsWire-theme-\(UUID().uuidString).zip")
		try data.write(to: zip)
		return DownloadedTheme(zipPath: zip.path(percentEncoded: false))
	}

	/// A theme's details without installing it, and whether one by that name is installed already.
	func inspectTheme(_ params: InstallThemeParams) throws -> InspectedTheme {
		let url = URL(filePath: params.path, directoryHint: .isDirectory)
		let theme: ArticleTheme
		do {
			theme = try ArticleTheme(url: url, isAppTheme: false)
		} catch {
			throw CoreServiceError(code: "invalidTheme", message: "This theme can’t be used: \(error.localizedDescription)")
		}
		let name = ArticleTheme.themeNameForPath(url.path)
		return InspectedTheme(name: theme.name, creatorName: theme.creatorName, creatorHomePage: theme.creatorHomePage, version: theme.version, isInstalled: themeStore.installedThemeURL(named: name) != nil)
	}

	func deleteTheme(_ params: ThemeNameParams) throws {
		guard let url = themeStore.installedThemeURL(named: params.name) else {
			throw CoreServiceError.notFound("Installed theme \(params.name)")
		}
		try FileManager.default.removeItem(at: url)
		themeStore.emptyCache()
	}
}

// MARK: - Params and results

struct ThemeInfo: Encodable {
	let name: String
	let creatorName: String
	let creatorHomePage: String
	let version: String
	/// Ships with the app. Installed themes can be deleted; these can't.
	let isAppTheme: Bool
	let isDefault: Bool
}

struct InstallThemeParams: Decodable {
	/// A folder whose name ends in .nnwtheme.
	let path: String
}

struct ThemeURLParams: Decodable {
	let url: String
}

struct DownloadedTheme: Encodable {
	/// The downloaded zip archive, in the temporary folder.
	let zipPath: String
}

struct InspectedTheme: Encodable {
	let name: String
	let creatorName: String
	let creatorHomePage: String
	let version: String
	/// Installing it replaces the installed theme of the same name.
	let isInstalled: Bool
}

struct ThemeNameParams: Decodable {
	let name: String
}

/// Finds and caches themes by name. Names are the folder names without .nnwtheme.
@MainActor final class ThemeStore {

	/// The themes that ship with the app. NetNewsWireCore sets it to Themes next to the exe.
	var appThemesFolder: URL?

	let installedThemesFolder: URL = {
		let path = Platform.dataSubfolder(forApplication: nil, folderName: "Themes") ?? NSTemporaryDirectory()
		return URL(filePath: path, directoryHint: .isDirectory)
	}()

	private var cache = [String: ArticleTheme]()

	var defaultThemeName: String {
		ArticleTheme.defaultTheme.name
	}

	/// The default theme first, then the rest sorted case-insensitively, as on the Mac.
	func themeNames() -> [String] {
		let names = Set(themeFolders(in: appThemesFolder).map(Self.name) + themeFolders(in: installedThemesFolder).map(Self.name))
		return [defaultThemeName] + names.sorted { $0.compare($1, options: .caseInsensitive) == .orderedAscending }
	}

	/// The named theme. Nil if there's none by that name or it can't be loaded. App themes win over installed ones.
	func theme(named name: String) -> ArticleTheme? {
		if name == defaultThemeName {
			return .defaultTheme
		}
		if let theme = cache[name] {
			return theme
		}
		let theme: ArticleTheme?
		if let url = themeFolders(in: appThemesFolder).first(where: { Self.name($0) == name }) {
			theme = try? ArticleTheme(url: url, isAppTheme: true)
		} else if let url = installedThemeURL(named: name) {
			theme = try? ArticleTheme(url: url, isAppTheme: false)
		} else {
			theme = nil
		}
		cache[name] = theme
		return theme
	}

	func installedThemeURL(named name: String) -> URL? {
		themeFolders(in: installedThemesFolder).first { Self.name($0) == name }
	}

	func emptyCache() {
		cache.removeAll()
	}

	private func themeFolders(in folder: URL?) -> [URL] {
		guard let folder, let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
			return []
		}
		return contents.filter { $0.pathExtension.lowercased() == "nnwtheme" }
	}

	private static func name(_ url: URL) -> String {
		ArticleTheme.themeNameForPath(url.path)
	}
}

extension CoreService {

	/// As the Mac's ArticleThemeDownloader.
	static let maximumThemeDownloadSize = 10_000_000
}
