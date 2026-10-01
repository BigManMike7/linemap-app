// swift-tools-version: 6.2
import PackageDescription

// Swift 6.2 "approachable concurrency" features. No default actor isolation:
// this is a library, so its APIs stay nonisolated and the app decides where they run.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "LineMapCore",
    // macOS is listed only so `swift test` can run on the CI host without a simulator.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LineMapCore", targets: ["LineMapCore"]),
    ],
    targets: [
        .target(name: "LineMapCore", swiftSettings: swiftSettings),
        .testTarget(
            name: "LineMapCoreTests",
            dependencies: ["LineMapCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
