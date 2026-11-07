import CoreGraphics
import Foundation
import ImageIO
import RippleKit

/// Reads a video's facts and a picture from it. `LiveVideoSource` asks ffmpeg; `FixtureVideoSource` makes both up,
/// so snapshots and the self-test need no ffmpeg and no real videos.
protocol VideoSource: Sendable {
    func read(_ url: URL) async -> Result<VideoFile, VideoProblem>
    func picture(for file: VideoFile) async -> CGImage?
}

enum VideoSources {
    /// Test and snapshot runs use made-up videos and a stand-in builder, unless RIPPLE_REAL_DVD=1 asks for the real programs.
    static var useFixtures: Bool { Store.isOverridden && ProcessInfo.processInfo.environment["RIPPLE_REAL_DVD"] != "1" }

    static func make() -> any VideoSource {
        if useFixtures { return FixtureVideoSource() }
        return LiveVideoSource(ffmpeg: ffmpeg)
    }

    /// The programs a build runs, inside the app. A missing one makes the build say so before it starts.
    static var tools: DVDTools {
        let bin = Bundle.main.resourceURL?.appending(path: "bin") ?? URL(fileURLWithPath: "/nonexistent")
        return DVDTools(ffmpeg: ffmpeg ?? bin.appending(path: "ffmpeg"), dvdauthor: bin.appending(path: "dvdauthor"), spumux: bin.appending(path: "spumux"))
    }

    /// ffmpeg inside the app, or the one RIPPLE_FFMPEG names while the tools are not yet carried (S-048).
    static var ffmpeg: URL? {
        let candidates = [Bundle.main.resourceURL?.appending(path: "bin/ffmpeg"),
                          ProcessInfo.processInfo.environment["RIPPLE_FFMPEG"].map { URL(fileURLWithPath: $0) }]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct LiveVideoSource: VideoSource {
    var ffmpeg: URL?

    func read(_ url: URL) async -> Result<VideoFile, VideoProblem> {
        guard let ffmpeg else { return .failure(.toolMissing) }
        return (try? await VideoProbe.read(url, ffmpeg: ffmpeg)) ?? .failure(.unreadable)
    }

    func picture(for file: VideoFile) async -> CGImage? {
        guard let ffmpeg else { return nil }
        let out = FileManager.default.temporaryDirectory.appending(path: "ripple-thumb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let at = min(10, max(0, file.seconds * 0.1))
        guard let r = try? await ProcessRunner.run(ffmpeg, DVDAuthoring.thumbnailArguments(input: file.url, output: out, at: at)), r.status == 0,
              let data = try? Data(contentsOf: out), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decode now: the file is deleted when this function returns.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return image
    }
}

/// File names decide the result: "protected" and "broken" fail; "pal" is 25 frames a second; "old" is 4:3; anything else is a 16:9 video whose length comes from the name.
struct FixtureVideoSource: VideoSource {
    func read(_ url: URL) async -> Result<VideoFile, VideoProblem> {
        let name = url.lastPathComponent.lowercased()
        if name.contains("protected") { return .failure(.copyProtected) }
        if name.contains("broken") { return .failure(.unreadable) }
        let seconds = Double(300 + abs(url.lastPathComponent.hashValue % 3000))
        return .success(VideoFile(url: url, title: VideoProbe.defaultTitle(for: url), bytes: Int(seconds * 450_000), seconds: seconds,
                                  width: 1280, height: 720, framesPerSecond: name.contains("pal") ? 25 : 29.97, displayAspect: name.contains("old") ? 4.0 / 3 : 16.0 / 9,
                                  hasAudio: true))
    }

    func picture(for file: VideoFile) async -> CGImage? { Self.gradient(seed: abs(file.title.hashValue)) }

    static func gradient(seed: Int) -> CGImage? {
        let hue = Double(seed % 360) / 360
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let colors = [CGColor(red: 0.2 + 0.5 * hue, green: 0.4, blue: 0.8 - 0.4 * hue, alpha: 1), CGColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1)]
        guard let ctx, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 64, y: 36), options: [])
        return ctx.makeImage()
    }
}
