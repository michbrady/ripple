// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ripple",
    platforms: [.macOS(.v26)],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "RippleKit"),
        .executableTarget(
            name: "Ripple",
            dependencies: ["RippleKit"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "RippleKitTests", dependencies: ["RippleKit"]),
    ]
)
