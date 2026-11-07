import Foundation

/// NTSC (the US and Japan) or PAL (Europe and most of the rest): how many lines and frames a second the disc is made for.
public enum TVStandard: String, CaseIterable, Identifiable, Sendable {
    case ntsc, pal

    public var id: String { rawValue }
    public var title: String { self == .ntsc ? "NTSC" : "PAL" }
    public var width: Int { 720 }
    public var height: Int { self == .ntsc ? 480 : 576 }
    /// "30000/1001" for NTSC, "25" for PAL, as ffmpeg writes a frame rate.
    public var frameRate: String { self == .ntsc ? "30000/1001" : "25" }
    public var framesPerSecond: Double { self == .ntsc ? 30000.0 / 1001.0 : 25 }
    /// What dvdauthor and spumux call it.
    public var format: String { rawValue }

    /// 25 and 50 frames a second suggest PAL, anything else NTSC. The first video decides when they differ.
    public static func suggest(for files: [VideoFile]) -> TVStandard {
        guard let first = files.first else { return .ntsc }
        let fps = first.framesPerSecond
        return (abs(fps - 25) < 0.6 || abs(fps - 50) < 1.2) ? .pal : .ntsc
    }

    /// True when the videos disagree about NTSC and PAL, so the window can say so.
    public static func mixed(_ files: [VideoFile]) -> Bool {
        Set(files.map { suggest(for: [$0]) }).count > 1
    }
}

/// How good the picture will be, from the bit rate the disc leaves for each second of video.
public enum DVDQuality: String, Sendable {
    case excellent, good, reduced, tooLong

    public static func of(videoKbps: Int) -> DVDQuality {
        switch videoKbps {
        case 5_000...: .excellent
        case 3_500...: .good
        case 2_500...: .reduced
        default: .tooLong
        }
    }

    public var title: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .reduced: "Reduced"
        case .tooLong: "Too long"
        }
    }
}

/// Everything decided before any converting starts: how much each second of video may use, and whether it all fits.
public struct DVDPlan: Equatable, Sendable {
    public static let singleLayerBlocks = 2_298_496
    public static let dualLayerBlocks = 4_173_824
    public static let audioKbps = 192
    public static let maxVideoKbps = 9_000
    /// Room for the menus, the disc's file structure, and a safety margin (3 percent of the disc).
    static let menuBlocks = 12_000
    static let safety = 0.97

    public var files: [VideoFile]
    public var standard: TVStandard
    public var capacityBlocks: Int

    public init(files: [VideoFile], standard: TVStandard, capacityBlocks: Int = DVDPlan.singleLayerBlocks) {
        self.files = files; self.standard = standard; self.capacityBlocks = capacityBlocks
    }

    public var totalSeconds: Double { files.reduce(0) { $0 + $1.seconds } }

    /// The disc a blank in the drive gives, or one single-layer disc when there is none.
    public static func capacity(for state: BurnDeviceState) -> Int {
        if case .ready(let media) = state, media.kind == .dvd, media.blocksFree > 0 { return media.blocksFree }
        return singleLayerBlocks
    }

    /// Kilobits a second for the picture, the same for every title, never above the DVD limit.
    public var videoKbps: Int {
        guard totalSeconds > 0 else { return Self.maxVideoKbps }
        let usableBits = Double(max(0, capacityBlocks - Self.menuBlocks)) * 2_048 * 8 * Self.safety
        let kbps = usableBits / totalSeconds / 1_000 - Double(Self.audioKbps)
        return max(0, min(Self.maxVideoKbps, Int(kbps)))
    }

    public var quality: DVDQuality { DVDQuality.of(videoKbps: videoKbps) }

    /// Blocks the converted videos, the menus, and the disc structure will use.
    public var blocksNeeded: Int {
        guard !files.isEmpty else { return 0 }
        let bits = totalSeconds * Double(videoKbps + Self.audioKbps) * 1_000
        return Int((bits / 8 / 2_048 / Self.safety).rounded(.up)) + Self.menuBlocks
    }

    /// Longest total length that still reaches at least "Reduced" quality on this disc.
    public var longestReducedSeconds: Double {
        let usableBits = Double(max(0, capacityBlocks - Self.menuBlocks)) * 2_048 * 8 * Self.safety
        return usableBits / Double(2_500 + Self.audioKbps) / 1_000
    }

    public enum Fit: Equatable, Sendable {
        case nothingToBurn
        case fits
        /// Remove this many seconds of video.
        case tooLong(removeSeconds: Double)
    }

    public var fit: Fit {
        guard !files.isEmpty else { return .nothingToBurn }
        return totalSeconds <= longestReducedSeconds ? .fits : .tooLong(removeSeconds: totalSeconds - longestReducedSeconds)
    }

    /// Converted size in bytes, for the "free space" check on the Mac.
    public var convertedBytes: Int { blocksNeeded * 2_048 }

    public static func lengthText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
