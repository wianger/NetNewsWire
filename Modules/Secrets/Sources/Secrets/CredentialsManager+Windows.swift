//
//  CredentialsManager+Windows.swift
//  Secrets
//
//  Windows backend for CredentialsManager: generic credentials in Windows Credential
//  Manager (Credential Locker), which encrypts them per user with DPAPI. Same API as
//  the keychain version in CredentialsManager.swift.
//

#if os(Windows)

import Foundation
import Synchronization
import WinSDK
import RSCore
import ErrorLog

public struct CredentialsManager {

	static let CredentialsManagerErrorSourceID = 100

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "CredentialsManager")

	/// Credential Manager identifies a credential by its target name alone, so the
	/// target carries everything the keychain query matches on: type, server and username.
	static func targetName(type: CredentialsType, server: String, username: String) -> String {
		"NetNewsWire/\(type.rawValue)/\(server)/\(username)"
	}

	/// Adds the credentials, or replaces the secret of credentials already stored
	/// for the same type, server and username.
	public static func storeCredentials(_ credentials: Credentials, server: String) throws {
		if Platform.isRunningUnitTests {
			unitTestCredentials.withLock { $0[targetName(type: credentials.type, server: server, username: credentials.username)] = credentials }
			return
		}
		var blob = Array(credentials.secret.utf8)
		guard blob.count <= Int(CRED_MAX_CREDENTIAL_BLOB_SIZE) else {
			let error = CredentialsError.keychainStoreFailure(status: OSStatus(ERROR_BAD_LENGTH))
			logger.error("CredentialsManager: storeCredentials failed — secret is \(blob.count, privacy: .public) bytes, over the Credential Manager limit")
			postAppDidEncounterError(operation: "Storing credentials", error: error)
			throw error
		}

		let target = targetName(type: credentials.type, server: server, username: credentials.username)
		let didWrite = target.withCString(encodedAs: UTF16.self) { targetPointer in
			credentials.username.withCString(encodedAs: UTF16.self) { usernamePointer in
				blob.withUnsafeMutableBufferPointer { blobBuffer in
					var credential = CREDENTIALW()
					credential.`Type` = DWORD(CRED_TYPE_GENERIC)
					credential.TargetName = UnsafeMutablePointer(mutating: targetPointer)
					credential.UserName = UnsafeMutablePointer(mutating: usernamePointer)
					credential.CredentialBlobSize = DWORD(blobBuffer.count)
					credential.CredentialBlob = blobBuffer.baseAddress
					credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
					return CredWriteW(&credential, 0)
				}
			}
		}

		guard didWrite else {
			let status = lastErrorStatus()
			logger.error("CredentialsManager: storeCredentials failed — \(CredentialsError.keychainStatusMessage(status), privacy: .public)")
			let error = CredentialsError.keychainStoreFailure(status: status)
			postAppDidEncounterError(operation: "Storing credentials", error: error)
			throw error
		}
	}

	public static func retrieveCredentials(type: CredentialsType, server: String, username: String) throws -> Credentials? {
		let target = targetName(type: type, server: server, username: username)
		if Platform.isRunningUnitTests {
			return unitTestCredentials.withLock { $0[target] }
		}
		var pointer: PCREDENTIALW?
		let didRead = target.withCString(encodedAs: UTF16.self) { targetPointer in
			CredReadW(targetPointer, DWORD(CRED_TYPE_GENERIC), 0, &pointer)
		}

		guard didRead else {
			let status = lastErrorStatus()
			guard status != OSStatus(ERROR_NOT_FOUND) else {
				return nil
			}
			logger.error("CredentialsManager: retrieveCredentials failed — \(CredentialsError.keychainStatusMessage(status), privacy: .public) for type \(type.rawValue, privacy: .public)")
			let error = CredentialsError.keychainRetrieveFailure(status: status)
			postAppDidEncounterError(operation: "Retrieving credentials", error: error)
			throw error
		}
		defer {
			CredFree(pointer)
		}

		guard let credential = pointer?.pointee, let blob = credential.CredentialBlob else {
			return nil
		}
		let secret = String(decoding: UnsafeBufferPointer(start: blob, count: Int(credential.CredentialBlobSize)), as: UTF8.self)
		return Credentials(type: type, username: username, secret: secret)
	}

	public static func removeCredentials(type: CredentialsType, server: String, username: String) throws {
		let target = targetName(type: type, server: server, username: username)
		if Platform.isRunningUnitTests {
			unitTestCredentials.withLock { $0[target] = nil }
			return
		}
		let didDelete = target.withCString(encodedAs: UTF16.self) { targetPointer in
			CredDeleteW(targetPointer, DWORD(CRED_TYPE_GENERIC), 0)
		}

		guard didDelete else {
			let status = lastErrorStatus()
			guard status != OSStatus(ERROR_NOT_FOUND) else {
				return
			}
			logger.error("CredentialsManager: removeCredentials failed — \(CredentialsError.keychainStatusMessage(status), privacy: .public)")
			let error = CredentialsError.keychainRemoveFailure(status: status)
			postAppDidEncounterError(operation: "Removing credentials", error: error)
			throw error
		}
	}
}

private extension CredentialsManager {

	/// While unit tests run, credentials stay in memory instead of the user's Credential Manager,
	/// as the data folder is a temporary folder (see Platform.unitTestDataFolder).
	static let unitTestCredentials = Mutex([String: Credentials]())

	static func lastErrorStatus() -> OSStatus {
		OSStatus(bitPattern: GetLastError())
	}

	static func postAppDidEncounterError(operation: String, error: CredentialsError) {
		let errorLogUserInfo = ErrorLogUserInfoKey.userInfo(sourceName: "CredentialsManager", sourceID: Self.CredentialsManagerErrorSourceID, operation: operation, errorMessage: error.localizedDescription)
		NotificationCenter.default.postOnMainThread(name: .appDidEncounterError, object: self, userInfo: errorLogUserInfo)
	}
}

extension CredentialsError {

	/// The system message for a Win32 error code.
	static func keychainStatusMessage(_ status: OSStatus) -> String {
		var buffer: UnsafeMutablePointer<WCHAR>?
		let flags = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
		// With FORMAT_MESSAGE_ALLOCATE_BUFFER, lpBuffer is really a pointer to the buffer pointer.
		let length = withUnsafeMutablePointer(to: &buffer) { bufferPointer in
			bufferPointer.withMemoryRebound(to: WCHAR.self, capacity: 1) { lpBuffer in
				FormatMessageW(flags, nil, DWORD(bitPattern: status), 0, lpBuffer, 0, nil)
			}
		}
		defer {
			LocalFree(buffer)
		}
		guard length > 0, let buffer else {
			return "error \(status)"
		}
		let message = String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)), as: UTF16.self)
		return "error \(status): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
	}
}

#endif
