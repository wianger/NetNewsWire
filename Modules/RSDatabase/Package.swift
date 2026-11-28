// swift-tools-version:6.2
import PackageDescription

// Manifests are evaluated on the host. Apple hosts (Xcode, including iOS builds) use
// Objective-C FMDB (RSDatabaseObjC) and the system SQLite. Other hosts (Windows, Linux)
// have no Objective-C runtime: they use the Swift FMDB in Sources/RSDatabase/SwiftFMDB
// and the SQLite amalgamation in Sources/CSQLite.
#if os(macOS) || os(iOS)
let isApplePlatform = true
#else
let isApplePlatform = false
#endif

let swiftSettings: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances")
]

var products: [Product] = [
	.library(
		name: "RSDatabase",
		type: .dynamic,
		targets: ["RSDatabase"])
]
var targets: [Target]

if isApplePlatform {
	products.append(
		.library(
			name: "RSDatabaseObjC",
			type: .dynamic,
			targets: ["RSDatabaseObjC"])
	)
	targets = [
		.target(
			name: "RSDatabase",
			dependencies: ["RSDatabaseObjC"],
			exclude: ["SwiftFMDB"],
			swiftSettings: swiftSettings
		),
		.target(
			name: "RSDatabaseObjC",
			dependencies: []
		),
		.testTarget(
			name: "RSDatabaseTests",
			dependencies: ["RSDatabase", "RSDatabaseObjC"])
	]
} else {
	targets = [
		.target(
			name: "RSDatabase",
			// RSCore provides the Logger that os provides on Apple platforms.
			dependencies: ["CSQLite", "RSCore"],
			swiftSettings: swiftSettings
		),
		.target(
			name: "CSQLite",
			exclude: ["README.md"],
			cSettings: [
				// Matches the features of Apple's system SQLite that NetNewsWire relies on.
				.define("SQLITE_THREADSAFE", to: "2"),
				.define("SQLITE_ENABLE_FTS3"),
				.define("SQLITE_ENABLE_FTS3_PARENTHESIS"),
				.define("SQLITE_ENABLE_FTS4"),
				.define("SQLITE_ENABLE_FTS5"),
				.define("SQLITE_ENABLE_RTREE"),
				.define("SQLITE_ENABLE_SNAPSHOT"),
				.define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
				.define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
				.define("SQLITE_OMIT_LOAD_EXTENSION"),
				.define("SQLITE_OMIT_SHARED_CACHE")
			]
		),
		.testTarget(
			name: "RSDatabaseTests",
			dependencies: ["RSDatabase"])
	]
}

let package = Package(
	name: "RSDatabase",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: products,
	dependencies: isApplePlatform ? [] : [.package(path: "../RSCore")],
	targets: targets
)
