// swift-tools-version:6.2
import PackageDescription

// Manifests are evaluated on the host. Apple hosts (Xcode, including iOS builds) get the
// full package; other hosts (Windows, Linux) leave out the AppKit Objective-C code and the
// xib resources, and use swift-crypto in place of CryptoKit.
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
	.library(name: "RSCore", type: .dynamic, targets: ["RSCore"])
]
var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var targets: [Target] = []

if isApplePlatform {
	products += [
		.library(name: "RSCoreObjC", type: .dynamic, targets: ["RSCoreObjC"]),
		.library(name: "RSCoreResources", type: .static, targets: ["RSCoreResources"])
	]
	coreDependencies.append("RSCoreObjC")
	targets += [
		.target(
			name: "RSCoreObjC",
			dependencies: [],
			cSettings: [
				.headerSearchPath("include")
			]
		),
		.target(
			name: "RSCoreResources",
			resources: [
				.process("Resources/WebViewWindow.xib"),
				.process("Resources/IndeterminateProgressWindow.xib")
			],
			swiftSettings: swiftSettings
		)
	]
} else {
	packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "5.2.0"))
	coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
}

targets += [
	.target(
		name: "RSCore",
		dependencies: coreDependencies,
		swiftSettings: swiftSettings
	),
	.testTarget(
		name: "RSCoreTests",
		dependencies: ["RSCore"],
		resources: [.copy("Resources")],
		swiftSettings: [.swiftLanguageMode(.v6)]
	)
]

let package = Package(
	name: "RSCore",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: products,
	dependencies: packageDependencies,
	targets: targets
)
