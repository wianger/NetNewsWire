// swift-tools-version:6.2
import PackageDescription

// Manifests are evaluated on the host. Apple hosts (Xcode, including iOS builds) get the
// full package. Other hosts (Windows, Linux) have no CloudKit, so they leave out
// CloudKitSync and the iCloud account delegate; the iCloud account type is unavailable there.
#if os(macOS) || os(iOS)
let isApplePlatform = true
#else
let isApplePlatform = false
#endif

var packageDependencies: [Package.Dependency] = [
	.package(path: "../ActivityLog"),
	.package(path: "../Articles"),
	.package(path: "../ArticlesDatabase"),
	.package(path: "../FeedFinder"),
	.package(path: "../Secrets"),
	.package(path: "../ErrorLog"),
	.package(path: "../SyncDatabase"),
	.package(path: "../RSWeb"),
	.package(path: "../RSParser"),
	.package(path: "../RSCore"),
	.package(path: "../RSDatabase"),
	.package(path: "../NewsBlur")
]

var accountDependencies: [Target.Dependency] = [
	"RSCore",
	"RSDatabase",
	"RSParser",
	"RSWeb",
	"ActivityLog",
	"Articles",
	"ArticlesDatabase",
	"ErrorLog",
	"FeedFinder",
	"Secrets",
	"SyncDatabase",
	"NewsBlur"
]

var accountExcludes: [String] = []

if isApplePlatform {
	packageDependencies.append(.package(path: "../CloudKitSync"))
	accountDependencies.append("CloudKitSync")
} else {
	accountExcludes = [
		"CloudKit/CKRecord+Extensions.swift",
		"CloudKit/CloudKitAccountDelegate.swift",
		"CloudKit/CloudKitAccountZone.swift",
		"CloudKit/CloudKitAccountZoneDelegate.swift",
		"CloudKit/CloudKitArticlesZone.swift",
		"CloudKit/CloudKitArticlesZoneDelegate.swift",
		"CloudKit/CloudKitReceiveStatusOperation.swift",
		"CloudKit/CloudKitRemoteNotificationOperation.swift",
		"CloudKit/CloudKitSendStatusOperation.swift",
		"CloudKit/CloudKitStatsViewModel.swift",
		// ASWebAuthenticationSession. Windows signs in through the system browser instead.
		"Feedly/OAuthAccountAuthorizationOperation.swift"
	]
}

let package = Package(
	name: "Account",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(
			name: "Account",
			type: .dynamic,
			targets: ["Account"])
	],
	dependencies: packageDependencies,
	targets: [
		.target(
			name: "Account",
			dependencies: accountDependencies,
			exclude: accountExcludes,
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		),
		.testTarget(
			name: "AccountTests",
			dependencies: ["Account", "SyncDatabase"],
			resources: [
				.copy("JSON")
			],
			swiftSettings: [.swiftLanguageMode(.v6)]
		)
	]
)
