// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS(.v14)],
    targets: [
        // A few lines of Objective-C: the one thing Swift can't do here is
        // catch an Objective-C exception. See Sources/BridgeGuard.
        .target(name: "BridgeGuard", path: "Sources/BridgeGuard"),
        .executableTarget(
            name: "Browser",
            dependencies: ["BridgeGuard"],
            path: "Sources/Browser",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
