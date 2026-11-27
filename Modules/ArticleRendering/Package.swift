// swift-tools-version:6.2
import PackageDescription

// The article page: the renderer that fills the theme template, the default theme,
// and the scripts every article web view loads. Shared by Mac, iOS, and Windows.
// The platform pieces — page.html, main_mac.js/main_ios.js, the web view itself — stay in each app.

let package = Package(
	name: "ArticleRendering",
	defaultLocalization: "en",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(
			name: "ArticleRendering",
			type: .dynamic,
			targets: ["ArticleRendering"])
	],
	dependencies: [
		.package(path: "../RSCore"),
		.package(path: "../RSParser"),
		.package(path: "../RSWeb"),
		.package(path: "../Articles"),
		.package(path: "../Account")
	],
	targets: [
		.target(
			name: "ArticleRendering",
			dependencies: [
				"RSCore",
				"RSParser",
				"RSWeb",
				"Articles",
				"Account"
			],
			resources: [
				.copy("Resources/core.css"),
				.copy("Resources/stylesheet.css"),
				.copy("Resources/template.html"),
				.copy("Resources/main.js"),
				.copy("Resources/newsfoot.js")
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances"),
				.unsafeFlags(["-warnings-as-errors"])
			]
		),
		.testTarget(
			name: "ArticleRenderingTests",
			dependencies: ["ArticleRendering", "Articles"],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
