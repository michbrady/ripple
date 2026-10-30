// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ripple",
    platforms: [.macOS(.v26)],
    targets: [
        // LAME 3.100 encoder (LGPL, see Sources/CLame/LICENSE-LAME.txt). No decoder.
        .target(
            name: "CLame",
            exclude: ["LICENSE-LAME.txt"],
            cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("."), .unsafeFlags(["-w"])]
        ),
        // Two ioctls for reading audio CDs, which Swift cannot import as macros.
        .target(name: "CDShim"),
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "RippleKit", dependencies: ["CLame"]),
        .executableTarget(
            name: "Ripple",
            dependencies: ["RippleKit", "CDShim"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "RippleKitTests", dependencies: ["RippleKit"], resources: [.copy("Fixtures")]),
    ]
)
