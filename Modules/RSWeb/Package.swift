// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "RSWeb",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(
			name: "RSWeb",
			type: .dynamic,
			targets: ["RSWeb"])
	],
	dependencies: [
		.package(path: "../RSParser"),
		.package(path: "../RSCore")
	],
	targets: [
		.target(
			name: "RSWeb",
			dependencies: [
				"RSParser",
				"RSCore",
				.target(name: "CWinHTTP", condition: .when(platforms: [.windows]))
			],
			swiftSettings: [
				.unsafeFlags(["-warnings-as-errors"]),
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		),
		// WinHTTP for the Windows transport (WinHTTPClient). Empty elsewhere.
		.target(
			name: "CWinHTTP",
			linkerSettings: [
				.linkedLibrary("winhttp", .when(platforms: [.windows]))
			]
		),
		.testTarget(
			name: "RSWebTests",
			dependencies: [
				"RSWeb",
				.target(name: "CWinHTTP", condition: .when(platforms: [.windows]))
			])
	]
)
