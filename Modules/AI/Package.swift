// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "AI",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(
			name: "AI",
			type: .dynamic,
			targets: ["AI"])
	],
	dependencies: [
		.package(path: "../RSDatabase")
	],
	targets: [
		.target(
			name: "AI",
			dependencies: [
				"RSDatabase"
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		),
		.testTarget(
			name: "AITests",
			dependencies: [
				"AI"
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
