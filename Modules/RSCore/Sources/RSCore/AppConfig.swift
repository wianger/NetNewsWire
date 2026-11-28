//
//  AppConfig.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 6/26/24.
//  Copyright © 2024 Ranchero Software. All rights reserved.
//

import Foundation

@MainActor public final class AppConfig {

#if canImport(Darwin)
	public static let appName: String = (Bundle.main.infoDictionary!["CFBundleExecutable"]! as! String)
#else
	// Windows and Linux executables have no Info.plist.
	public static let appName: String = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? "NetNewsWire"
#endif

	public static let cacheFolder: URL = {

		let folderURL: URL

#if os(Windows)
		// The system caches directory is %LOCALAPPDATA% itself, shared by every app.
		folderURL = windowsLocalAppDataFolder.appending(path: "Caches", directoryHint: .isDirectory)
		createFolderIfNecessary(folderURL)
#else
		if let userCacheFolder = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
			folderURL = userCacheFolder
		} else {
			let bundleIdentifier = (Bundle.main.infoDictionary!["CFBundleIdentifier"]! as! String)
			let tempFolder = (NSTemporaryDirectory() as NSString).appendingPathComponent(bundleIdentifier)
			folderURL = URL(fileURLWithPath: tempFolder, isDirectory: true)
			createFolderIfNecessary(folderURL)
		}
#endif

		return folderURL
	}()

	/// Returns URL to subfolder in cache folder (creating the folder if it doesn’t exist)
	public static func cacheSubfolder(named name: String) -> URL {
		ensureSubfolder(named: name, folderURL: cacheFolder)
	}

	public static let dataFolder: URL = {

#if os(macOS)
		var dataFolder = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		dataFolder = dataFolder.appendingPathComponent(appName)
#elseif os(iOS)
		var dataFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
#elseif os(Windows)
		// %LOCALAPPDATA%, not the roaming folder: the databases are large and machine-specific.
		let dataFolder = windowsLocalAppDataFolder
#else
		let applicationSupportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
		let dataFolder = unitTestFolder ?? applicationSupportFolder.appending(path: appName, directoryHint: .isDirectory)
#endif

		createFolderIfNecessary(dataFolder)
		return dataFolder
	}()

	/// Returns URL to subfolder in data folder (creating the folder if it doesn’t exist)
	public static func dataSubfolder(named name: String) -> URL {
		ensureSubfolder(named: name, folderURL: dataFolder)
	}

	public static func ensureSubfolder(named name: String, folderURL: URL) -> URL {

		let folder = folderURL.appendingPathComponent(name, isDirectory: true)
		createFolderIfNecessary(folder)
		return folder
	}

	/// Returns the given absolute path relative to `dataFolder`. Used to label
	/// files in user-visible diagnostics (Activity Log, Error Log).
	public static func relativeDataPath(_ absolutePath: String) -> String {
		let prefix = dataFolder.path + "/"
		if absolutePath.hasPrefix(prefix) {
			return String(absolutePath.dropFirst(prefix.count))
		}
		return absolutePath
	}
}

private extension AppConfig {

#if !canImport(Darwin)
	/// Shared with Platform's data folder lookup, so a test process has one data folder.
	static var unitTestFolder: URL? {
		Platform.unitTestDataFolder
	}
#endif

#if os(Windows)
	/// %LOCALAPPDATA%\\<appName>, the root of everything NetNewsWire stores on Windows.
	static let windowsLocalAppDataFolder: URL = {
		if let unitTestFolder {
			return unitTestFolder
		}
		let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
		return URL(filePath: localAppData, directoryHint: .isDirectory).appending(path: appName, directoryHint: .isDirectory)
	}()
#endif

	static func createFolderIfNecessary(_ folderURL: URL) {
		try! FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
	}
}
