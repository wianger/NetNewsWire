// swift-tools-version: 6.2

import PackageDescription

// NetNewsWireCore: the Swift core of NetNewsWire for Windows, built as a DLL
// with a narrow C ABI (SE-0495 `@c`) consumed by the C#/WinUI 3 app.
//
// - CoreService: the facade — JSON requests and events over the shared modules. Testable.
// - NetNewsWireCore: exports CoreService over the C ABI.
//
// See Technotes/WindowsPort.md.

let swiftSettings: [SwiftSetting] = [
	.swiftLanguageMode(.v6),
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
	name: "NetNewsWireCore",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(name: "NetNewsWireCore", type: .dynamic, targets: ["NetNewsWireCore"])
	],
	dependencies: [
		.package(path: "../../Modules/RSCore"),
		.package(path: "../../Modules/RSParser"),
		.package(path: "../../Modules/Articles"),
		.package(path: "../../Modules/Account"),
		.package(path: "../../Modules/ArticleRendering"),
		.package(path: "../../Modules/Images"),
		.package(path: "../../Modules/Secrets"),
		.package(path: "../../Modules/RSWeb")
	],
	targets: [
		.target(
			name: "CoreService",
			dependencies: [
				.product(name: "RSCore", package: "RSCore"),
				.product(name: "Articles", package: "Articles"),
				.product(name: "Account", package: "Account"),
				.product(name: "ArticleRendering", package: "ArticleRendering"),
				.product(name: "Images", package: "Images"),
				.product(name: "Secrets", package: "Secrets"),
				.product(name: "RSWeb", package: "RSWeb")
			],
			resources: [
				// The Windows counterpart of Mac/MainWindow/Detail/page.html. Like it, no doctype:
				// quirks mode makes CSS class names case-insensitive, which the default
				// stylesheet's text size selectors rely on.
				.copy("Resources/page.html"),
				// Images needs these from the app: the template for generated feed icons
				// (rendered from the Mac app's faviconTemplateImage.pdf) and NetNewsWire's own feed icon.
				.copy("Resources/faviconTemplate.png"),
				.copy("Resources/nnwFeedIcon.png")
			],
			swiftSettings: swiftSettings
		),
		.target(
			name: "NetNewsWireCore",
			dependencies: ["CoreService"],
			swiftSettings: swiftSettings
		),
		.testTarget(
			name: "CoreServiceTests",
			dependencies: [
				"CoreService",
				.product(name: "RSCore", package: "RSCore"),
				.product(name: "RSParser", package: "RSParser"),
				.product(name: "Account", package: "Account"),
				.product(name: "RSWeb", package: "RSWeb"),
				.product(name: "Secrets", package: "Secrets")
			],
			swiftSettings: swiftSettings
		)
	]
)
