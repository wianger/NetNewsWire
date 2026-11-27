//
//  CoreService+Accounts.swift
//  CoreService
//
//  Sync accounts, added as the Mac's account sheets add them (Mac/Preferences/Accounts):
//  validate the credentials with the service, refuse a duplicate, create the account, store
//  the credentials (Windows Credential Manager, through Secrets), then refresh.
//
//  Feedbin, Feedly, and Inoreader are restricted in developer builds on the Mac and iOS, since they
//  need NetNewsWire's API agreements or keys; the Windows build is a developer build, so it
//  offers the others. Feedly also needs its OAuth redirect, `netnewswire://auth/feedly`.
//

import Foundation
import RSCore
import Account
import Secrets

extension CoreService {

	func accountTypes() -> [AccountTypeInfo] {
		AccountTypeInfo.all.filter { !$0.accountType.isDeveloperRestricted }
	}

	func addAccount(_ params: AddAccountParams) async throws -> AddedAccount {
		guard let typeInfo = accountTypes().first(where: { $0.type == params.type }) else {
			throw CoreServiceError.invalidParams("\(params.type) isn’t an account type that can be added here.")
		}
		let accountType = typeInfo.accountType
		let username = params.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let password = params.password ?? ""
		let apiToken = params.apiToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

		let endpoint: URL?
		switch accountType {
		case .freshRSS:
			guard let url = params.apiURL.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }), url.isHTTPOrHTTPSURL else {
				throw CoreServiceError.invalidParams("Enter the API URL, such as https://fresh.rss.net/api/greader.php.")
			}
			endpoint = url
		case .bazQux:
			endpoint = URL(string: ReaderAPIVariant.bazQux.host)
		case .theOldReader:
			endpoint = URL(string: ReaderAPIVariant.theOldReader.host)
		case .inoreader:
			endpoint = URL(string: ReaderAPIVariant.inoreader.host)
		case .miniflux:
			guard let url = params.apiURL.flatMap(Miniflux.normalizedEndpointURL) else {
				throw CoreServiceError.invalidParams("Enter the Miniflux server’s URL, such as https://miniflux.example.com.")
			}
			endpoint = url
		default:
			endpoint = nil
		}

		let credentials: Credentials
		switch accountType {
		case .miniflux where !apiToken.isEmpty:
			credentials = Credentials(type: .minifluxAPIToken, username: "", secret: apiToken)
		default:
			guard !username.isEmpty, !password.isEmpty else {
				throw CoreServiceError.invalidParams(accountType == .miniflux ? "Enter a username and password, or an API token." : "Enter a username and password.")
			}
			credentials = Credentials(type: Self.credentialsType(for: accountType), username: username, secret: password)
		}

		// Miniflux's username comes back from validation, when signing in with a token; the others are known now.
		if accountType != .miniflux, accountManager.duplicateServiceAccount(type: accountType, username: username, endpoint: endpoint) {
			throw CoreServiceError(code: "duplicate", message: "There is already an account of this type with that username.")
		}

		let validatedCredentials: Credentials?
		do {
			validatedCredentials = try await Account.validateCredentials(type: accountType, credentials: credentials, endpoint: endpoint)
		} catch {
			throw CoreServiceError(code: "failed", message: error.localizedDescription)
		}
		guard let validatedCredentials else {
			throw CoreServiceError(code: "invalidCredentials", message: accountType == .miniflux ? "Invalid username and password, or invalid API token." : "Invalid username and password.")
		}

		if accountType == .miniflux, accountManager.duplicateServiceAccount(type: .miniflux, username: validatedCredentials.username, endpoint: endpoint) {
			throw CoreServiceError(code: "duplicate", message: "There is already a Miniflux account for this user on this server.")
		}

		let account = accountManager.createAccount(type: accountType)
		do {
			account.endpointURL = endpoint
			// The Reader API and NewsBlur keep the password too, to sign in again when the token expires.
			if validatedCredentials.type != credentials.type {
				try account.storeCredentials(credentials)
			}
			try account.storeCredentials(validatedCredentials)
		} catch {
			accountManager.deleteAccount(account)
			throw CoreServiceError(code: "failed", message: "The credentials couldn’t be stored: \(error.localizedDescription)")
		}

		account.triggerRefreshAll()
		return AddedAccount(accountID: account.accountID, name: account.nameForDisplay)
	}

	/// Deletes a sync account and its data on this PC. The default local account can't be deleted.
	func deleteAccount(_ params: AccountIDParams) throws {
		guard let account = accountManager.existingAccount(accountID: params.accountID) else {
			throw CoreServiceError.notFound("Account \(params.accountID)")
		}
		guard account !== accountManager.defaultAccount else {
			throw CoreServiceError.invalidParams("The account on this PC can’t be deleted.")
		}
		for type in CredentialsType.allCases {
			try? account.removeCredentials(type: type)
		}
		accountManager.deleteAccount(account)
	}

	/// Turns an account off or on, as the checkbox in the Mac's account list does. An inactive account isn't shown or refreshed.
	func setAccountActive(_ params: SetAccountActiveParams) throws {
		guard let account = accountManager.existingAccount(accountID: params.accountID) else {
			throw CoreServiceError.notFound("Account \(params.accountID)")
		}
		account.isActive = params.isActive
	}
}

// MARK: - Params and results

struct AccountTypeInfo: Encodable {
	/// As AccountInfo's type: String(describing: AccountType).
	let type: String
	let name: String
	/// FreshRSS and Miniflux run on the user's own server.
	let needsAPIURL: Bool
	let apiURLPlaceholder: String?
	/// Miniflux takes an API token instead of a username and password.
	let acceptsAPIToken: Bool
	let signUpURL: String

	fileprivate let accountType: AccountType

	private enum CodingKeys: String, CodingKey {
		case type, name, needsAPIURL, apiURLPlaceholder, acceptsAPIToken, signUpURL
	}

	/// In the Mac's order.
	static let all: [AccountTypeInfo] = [
		AccountTypeInfo(.bazQux, needsAPIURL: false, signUpURL: "https://bazqux.com"),
		AccountTypeInfo(.feedbin, needsAPIURL: false, signUpURL: "https://feedbin.com/signup"),
		AccountTypeInfo(.feedly, needsAPIURL: false, signUpURL: "https://feedly.com"),
		AccountTypeInfo(.freshRSS, needsAPIURL: true, apiURLPlaceholder: "https://fresh.rss.net/api/greader.php", signUpURL: "https://freshrss.org"),
		AccountTypeInfo(.inoreader, needsAPIURL: false, signUpURL: "https://www.inoreader.com"),
		AccountTypeInfo(.miniflux, needsAPIURL: true, apiURLPlaceholder: "https://miniflux.example.com", acceptsAPIToken: true, signUpURL: "https://miniflux.app"),
		AccountTypeInfo(.newsBlur, needsAPIURL: false, signUpURL: "https://newsblur.com"),
		AccountTypeInfo(.theOldReader, needsAPIURL: false, signUpURL: "https://theoldreader.com")
	]

	private init(_ accountType: AccountType, needsAPIURL: Bool, apiURLPlaceholder: String? = nil, acceptsAPIToken: Bool = false, signUpURL: String) {
		self.accountType = accountType
		self.type = String(describing: accountType)
		self.name = accountType.displayName
		self.needsAPIURL = needsAPIURL
		self.apiURLPlaceholder = apiURLPlaceholder
		self.acceptsAPIToken = acceptsAPIToken
		self.signUpURL = signUpURL
	}
}

struct AddAccountParams: Decodable {
	/// From `accounts.types`.
	let type: String
	let username: String?
	let password: String?
	/// Miniflux only, instead of a username and password.
	let apiToken: String?
	/// FreshRSS and Miniflux.
	let apiURL: String?
}

struct AddedAccount: Encodable {
	let accountID: String
	let name: String
}

struct AccountIDParams: Decodable {
	let accountID: String
}

struct SetAccountActiveParams: Decodable {
	let accountID: String
	let isActive: Bool
}

// MARK: - Private

private extension CoreService {

	static func credentialsType(for accountType: AccountType) -> CredentialsType {
		switch accountType {
		case .freshRSS, .inoreader, .bazQux, .theOldReader:
			return .readerBasic
		case .newsBlur:
			return .newsBlurBasic
		case .miniflux:
			return .minifluxBasic
		default:
			return .basic
		}
	}
}

private extension URL {

	var isHTTPOrHTTPSURL: Bool {
		scheme?.lowercased() == "https" || scheme?.lowercased() == "http"
	}
}
