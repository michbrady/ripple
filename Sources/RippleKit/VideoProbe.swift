import Foundation

/// A video file Ripple can put on a Video DVD, as ffmpeg describes it.
public struct VideoFile: Equatable, Identifiable, Sendable {
    public var id: URL { url }
    public var url: URL
    /// The name the menu shows. It starts as the file's name and the user can change it.
    public var title: String
    public var bytes: Int
    public var seconds: Double
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double
    /// Width over height as it looks on a screen, after any non-square pixels.
    public var displayAspect: Double
    public var hasAudio: Bool

    public init(url: URL, title: String, bytes: Int, seconds: Double, width: Int, height: Int,
                framesPerSecond: Double, displayAspect: Double, hasAudio: Bool) {
        self.url = url; self.title = title; self.bytes = bytes; self.seconds = seconds; self.width = width; self.height = height
        self.framesPerSecond = framesPerSecond; self.displayAspect = displayAspect; self.hasAudio = hasAudio
    }

    /// 16:9 or wider counts as widescreen; anything narrower is made for a standard 4:3 screen.
    public var isWidescreen: Bool { displayAspect >= 1.55 }
}

/// Why a file cannot go on the disc. `message` is what the row says.
public enum VideoProblem: Error, Equatable, Sendable {
    case unreadable
    case noPicture
    case copyProtected
    case tooShort
    /// ffmpeg is not in the app, so no video can be read.
    case toolMissing

    public var message: String {
        switch self {
        case .unreadable: "Ripple cannot read this file."
        case .noPicture: "This file has no video."
        case .copyProtected: "This video is copy-protected, so Ripple cannot read it."
        case .tooShort: "This video is shorter than a second."
        case .toolMissing: "ffmpeg is missing from Ripple, so it cannot read videos."
        }
    }
}

public enum VideoProbe {
    /// Endings Ripple offers to a video. ffmpeg decides whether a particular file really works.
    public static let extensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "wmv", "mpg", "mpeg", "webm", "flv", "ts", "m2ts", "3gp", "vob", "mts"]

    public static func isVideoFile(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// "Summer_trip 2024" from "Summer_trip_2024.mp4", cut to fit a menu button.
    public static func defaultTitle(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        return DVDName.cleaned(stem, fallback: "Video")
    }

    /// Reads the text `ffmpeg -i file` prints. Cover pictures inside music files are not video.
    public static func parse(report: String, url: URL, bytes: Int) -> Result<VideoFile, VideoProblem> {
        let lower = report.lowercased()
        if lower.contains("drmi") || lower.contains("drms") || lower.contains("fairplay") || lower.contains("protected by drm") {
            return .failure(.copyProtected)
        }
        guard let duration = seconds(in: report) else { return .failure(.unreadable) }
        let videoLine = report.split(separator: "\n").map(String.init).first { line in
            line.contains("Video:") && !line.contains("attached pic")
        }
        guard let videoLine else { return .failure(.noPicture) }
        guard let size = size(in: videoLine) else { return .failure(.unreadable) }
        if duration < 1 { return .failure(.tooShort) }
        let fps = number(before: " fps", in: videoLine) ?? number(before: " tbr", in: videoLine) ?? 25
        let hasAudio = report.split(separator: "\n").contains { $0.contains("Audio:") }
        let aspect = displayAspect(in: videoLine, width: size.width, height: size.height)
        return .success(VideoFile(url: url, title: defaultTitle(for: url), bytes: bytes, seconds: duration, width: size.width, height: size.height,
                                  framesPerSecond: fps, displayAspect: aspect, hasAudio: hasAudio))
    }

    /// Asks ffmpeg about a file. ffmpeg exits with an error here (no output file given) but prints what it found.
    public static func read(_ url: URL, ffmpeg: URL) async throws -> Result<VideoFile, VideoProblem> {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let result = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-i", url.path])
        return parse(report: result.error + "\n" + result.output, url: url, bytes: bytes)
    }

    // MARK: Parsing helpers

    static func seconds(in report: String) -> Double? {
        guard let range = report.range(of: #"Duration: (\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
        let parts = report[range].dropFirst("Duration: ".count).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// The picture size is the first "1280x720" after the codec name, never a hex tag such as 0x31637661.
    static func size(in line: String) -> (width: Int, height: Int)? {
        guard let start = line.range(of: "Video:") else { return nil }
        let rest = String(line[start.upperBound...])
        guard let range = rest.range(of: #"(?<![0-9a-fA-Fx])(\d{2,5})x(\d{2,5})(?![0-9a-fA-F])"#, options: .regularExpression) else { return nil }
        let pair = rest[range].split(separator: "x")
        guard pair.count == 2, let w = Int(pair[0]), let h = Int(pair[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    static func number(before unit: String, in line: String) -> Double? {
        guard let end = line.range(of: unit) else { return nil }
        let head = line[..<end.lowerBound]
        let digits = head.reversed().prefix { $0.isNumber || $0 == "." }
        return Double(String(digits.reversed()))
    }

    static func displayAspect(in line: String, width: Int, height: Int) -> Double {
        if let range = line.range(of: #"DAR (\d+):(\d+)"#, options: .regularExpression) {
            let pair = line[range].dropFirst(4).split(separator: ":")
            if pair.count == 2, let a = Double(pair[0]), let b = Double(pair[1]), b > 0 { return a / b }
        }
        if let range = line.range(of: #"SAR (\d+):(\d+)"#, options: .regularExpression) {
            let pair = line[range].dropFirst(4).split(separator: ":")
            if pair.count == 2, let a = Double(pair[0]), let b = Double(pair[1]), b > 0 { return Double(width) / Double(height) * a / b }
        }
        return Double(width) / Double(height)
    }
}

/// Names that go on the menu and the disc.
public enum DVDName {
    public static let maxTitle = 40
    public static let maxDisc = 32     // a DVD volume name holds 32 characters

    /// Extra spaces and line breaks removed, cut to `maxTitle`, or `fallback` when nothing is left.
    public static func cleaned(_ text: String, fallback: String, limit: Int = maxTitle) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let cut = String(words.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? fallback : cut
    }

    /// The disc name as a volume label: capital letters, digits, and underscores, 32 at most.
    public static func volumeLabel(_ text: String) -> String {
        let mapped = text.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
        let trimmed = mapped.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return String((trimmed.isEmpty ? "VIDEO_DVD" : trimmed).prefix(maxDisc))
    }
}

extension VideoFile {
    /// "4:05", or "1:42:10" once it passes an hour.
    public var lengthText: String { Self.lengthText(seconds) }
    public static func lengthText(_ seconds: Double) -> String { DVDPlan.lengthText(seconds) }
}
