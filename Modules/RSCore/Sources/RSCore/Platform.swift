//
//  Platform.swift
//  RSCore
//
//  Created by Nate Weaver on 2020-01-02.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
#if canImport(os)
import os
#endif

public struct Platform {

	nonisolated private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "Platform")

	nonisolated public static var deviceHasiCloudAccount: Bool {
		#if canImport(Darwin)
		FileManager.default.ubiquityIdentityToken != nil
		#else
		false
		#endif
	}

	/// Returns true if the app is currently running unit tests.
	nonisolated public static var isRunningUnitTests: Bool {
		return _isRunningUnitTests
	}

	nonisolated private static let _isRunningUnitTests: Bool = {

		func checkIfRunningUnitTests() -> Bool {
			// Check multiple indicators to be super-reliable
			let environment = ProcessInfo.processInfo.environment

			// XCTest sets this environment variable
			if environment["XCTestConfigurationFilePath"] != nil {
				return true
			}

			// Check if XCTest framework is loaded
			if NSClassFromString("XCTestCase") != nil {
				return true
			}

			// Check command line arguments for test-related flags
			let arguments = ProcessInfo.processInfo.arguments
			if arguments.contains("-XCTest") || arguments.contains("test") {
				return true
			}

#if !canImport(Darwin)
			// SwiftPM test executables elsewhere: "<Target>-test-runner[.exe]" (Swift Build),
			// "<Package>PackageTests.xctest" (native build system), or xctest loading a bundle.
			let executableName = URL(fileURLWithPath: arguments.first ?? ProcessInfo.processInfo.processName).lastPathComponent.lowercased()
			let baseName = executableName.hasSuffix(".exe") ? String(executableName.dropLast(4)) : executableName
			if baseName.hasSuffix("-test-runner") || baseName.hasSuffix("packagetests") || baseName.hasSuffix(".xctest") || baseName == "xctest" {
				return true
			}
#endif

			return false
		}

		if checkIfRunningUnitTests() {
			Self.logger.info("RUNNING UNIT TESTS")
			return true
		}

		Self.logger.info("Not running unit tests")
		return false
	}()

#if !canImport(Darwin)
	/// While unit tests run, a fresh folder per test process, so tests never touch the user’s data.
	/// Both data folder lookups use it: this one and `AppConfig`’s. On Apple platforms tests run
	/// inside the app’s own sandbox container instead.
	nonisolated static let unitTestDataFolder: URL? = {
		guard isRunningUnitTests else {
			return nil
		}
		return FileManager.default.temporaryDirectory
			.appending(path: "NetNewsWireTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", directoryHint: .isDirectory)
	}()
#endif

	/// Get the path to a subfolder of the application's data folder (often `Application Support`).
	/// - Parameters:
	///   - appName: The name of the application.
	///   - folderName: The name of the subfolder in the application's data folder.
	public static func dataSubfolder(forApplication appName: String?, folderName: String) -> String? {
		guard let dataFolder = dataFile(forApplication: appName, filename: folderName) else {
			return nil
		}

		do {
			try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true, attributes: nil)
			return dataFolder.path
		} catch {
			Self.logger.error("Platform.dataSubfolder error: \(error.localizedDescription)")
		}

		return nil
	}
}

private extension Platform {

	static func dataFolder(forApplication appName: String?) -> URL? {
		var dataFolder: URL?

		do {
			#if os(macOS)
			dataFolder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)

			if let appName = appName ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String {
				dataFolder = dataFolder?.appendingPathComponent(appName)
			}
			#elseif os(Windows)
			// %LOCALAPPDATA%, not the roaming folder: the databases are large and machine-specific.
			guard let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] else {
				return nil
			}
			dataFolder = unitTestDataFolder ?? URL(filePath: localAppData, directoryHint: .isDirectory).appending(path: appName ?? "NetNewsWire", directoryHint: .isDirectory)
			#elseif os(Linux)
			dataFolder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
			dataFolder = unitTestDataFolder ?? dataFolder?.appending(path: appName ?? "NetNewsWire", directoryHint: .isDirectory)
			#else // iOS
			dataFolder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
			#endif

			if let dataFolder {
				try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true, attributes: nil)
			}

		} catch {
			Self.logger.error("Platform.dataFolder error: \(error.localizedDescription)")
		}

		return dataFolder
	}

	static func dataFile(forApplication appName: String?, filename: String) -> URL? {
		let dataFolder = self.dataFolder(forApplication: appName)
		return dataFolder?.appendingPathComponent(filename)
	}
}
