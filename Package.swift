// swift-tools-version: 6.2
import Foundation
import PackageDescription

// LAME (LGPL) is not compiled into the app. tools/build-lame.sh builds it as its own library, .lame/libmp3lame.0.dylib,
// and build.sh puts that file inside the app. Run tools/build-lame.sh before `swift build` or `swift test`.
let lameDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: ".lame").path

let package = Package(
    name: "Ripple",
    platforms: [.macOS(.v26)],
    targets: [
        // Only LAME's header and a note to link libmp3lame. The source is in vendor/lame.
        .systemLibrary(name: "CLame", path: "Sources/CLame"),
        // Two ioctls for reading audio CDs, which Swift cannot import as macros.
        .target(name: "CDShim"),
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(
            name: "RippleKit",
            dependencies: ["CLame"],
            linkerSettings: [.unsafeFlags(["-L", lameDir])]
        ),
        .executableTarget(
            name: "Ripple",
            dependencies: ["RippleKit", "CDShim"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // Inside the app, LAME is in Contents/Frameworks. The second path is for running from the build folder;
            // build.sh removes it from the finished app.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", lameDir])]
        ),
        .testTarget(
            name: "RippleKitTests",
            dependencies: ["RippleKit"],
            resources: [.copy("Fixtures")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", lameDir])]
        ),
    ]
)
