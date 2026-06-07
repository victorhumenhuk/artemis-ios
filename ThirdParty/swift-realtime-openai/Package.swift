// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "RealtimeAPI",
	platforms: [
		.iOS(.v17),
		.tvOS(.v17),
		.macOS(.v14),
		.visionOS(.v1),
		.macCatalyst(.v17),
	],
	products: [
		.library(name: "RealtimeAPI", targets: ["RealtimeAPI"]),
	],
	dependencies: [
		.package(url: "https://github.com/livekit/webrtc-xcframework.git", branch: "main"),
		.package(url: "https://github.com/SwiftyLab/MetaCodable.git", .upToNextMajor(from: "1.0.0")),
	],
	targets: [
		// Vendored dependency: suppress its (macro-generated) warnings so they
		// don't surface in our project. Our own patches stay warning-clean.
		.target(name: "Core", dependencies: [
			.product(name: "MetaCodable", package: "MetaCodable"),
			.product(name: "HelperCoders", package: "MetaCodable"),
		], swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
		.target(name: "WebSocket", dependencies: ["Core"], swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
		.target(name: "UI", dependencies: ["Core", "WebRTC"], swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
		.target(name: "RealtimeAPI", dependencies: ["Core", "WebSocket", "WebRTC", "UI"], swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
		.target(name: "WebRTC", dependencies: ["Core", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")], swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
	]
)
