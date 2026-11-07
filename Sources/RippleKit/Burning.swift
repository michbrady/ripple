import Foundation

/// The two kinds of disc Ripple burns.
public enum DiscType: String, CaseIterable, Identifiable, Sendable {
    /// A standard audio CD: it plays in old CD players, car stereos, and boom boxes. The MP3 files are turned into CD audio.
    case audio
    /// MP3 files, in folders if you like. M4A files are converted to MP3. Holds many hours, but only some players read it.
    case data
    /// A Video DVD: videos with a menu, made by `DVDBuilder`. It plays in any DVD player.
    case video

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .audio: "Audio CD"
        case .data: "MP3 Disc"
        case .video: "Video DVD"
        }
    }
    public var summary: String {
        switch self {
        case .audio: "Standard audio CD. Plays in old CD players, car stereos, and boom boxes. Holds about 80 minutes."
        case .data: "Holds many hours, with folders if you like. Needs a player that reads MP3 files. M4A files are converted to MP3."
        case .video: "Plays in any DVD player, with a menu. Holds about 2 hours of video."
        }
    }
}

/// The disc in the burner.
public struct BurnMedia: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case cd, dvd, other }

    public var kind: Kind
    /// "CD-R", "DVD-R", and so on.
    public var label: String
    /// 2,048-byte blocks for a data disc; for CD audio one block is 1/75 second.
    public var blocksFree: Int

    public init(kind: Kind, label: String, blocksFree: Int) {
        self.kind = kind
        self.label = label
        self.blocksFree = blocksFree
    }
}

/// What the burner can do right now.
public enum BurnDeviceState: Equatable, Sendable {
    case noDrive
    case noDisc
    /// A disc with something on it. `rewritable` discs could be erased.
    case notBlank(label: String, rewritable: Bool)
    case ready(BurnMedia)
}

/// Whether a list of files fits on the disc, with numbers for the capacity bar.
public struct BurnPlan: Equatable, Sendable {
    public static let sectorsPerSecond = 75
    /// An 80-minute CD, and a 700 MB CD, when no disc is in the drive yet.
    public static let defaultAudioBlocks = 80 * 60 * sectorsPerSecond
    public static let defaultDataBlocks = 700 * 1_024 * 1_024 / 2_048
    /// Every audio track has a two-second gap before it.
    static let gapBlocks = 2 * sectorsPerSecond
    /// Room for the directory records of a data disc.
    static let dataOverheadBlocks = 600

    public enum Fit: Equatable, Sendable {
        case fits
        /// Over by this many blocks.
        case over(blocks: Int)
        /// This kind of disc cannot go on that media.
        case wrongMedia(String)
        case nothingToBurn
    }

    public var items: [BurnItem]
    public var type: DiscType

    public init(items: [BurnItem], type: DiscType) {
        self.items = items
        self.type = type
    }

    public var totalSeconds: Double { items.reduce(0) { $0 + $1.seconds } }
    public var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    /// Blocks the files need: whole sectors plus gaps for audio, whole 2 KB blocks plus overhead for data.
    public var blocksNeeded: Int {
        guard !items.isEmpty else { return 0 }
        switch type {
        case .audio:
            return items.reduce(0) { $0 + Int((($1.seconds * Double(Self.sectorsPerSecond))).rounded(.up)) + Self.gapBlocks }
        case .data:
            return items.reduce(0) { $0 + ($1.discBytes + 2_047) / 2_048 } + Self.dataOverheadBlocks
        case .video:
            return 0   // a Video DVD is planned by DVDPlan, not by music files
        }
    }

    /// Blocks on the disc, or the default for a CD when there is none.
    public func capacityBlocks(on state: BurnDeviceState) -> Int {
        if case .ready(let media) = state { return media.blocksFree }
        return type == .audio ? Self.defaultAudioBlocks : Self.defaultDataBlocks
    }

    public func fit(on state: BurnDeviceState) -> Fit {
        guard !items.isEmpty else { return .nothingToBurn }
        if case .ready(let media) = state, type == .audio, media.kind != .cd {
            return .wrongMedia("An Audio CD needs a blank CD-R. This disc is a \(media.label).")
        }
        let over = blocksNeeded - capacityBlocks(on: state)
        return over > 0 ? .over(blocks: over) : .fits
    }

    /// 0 to 1 or more, for the capacity bar.
    public func usedFraction(on state: BurnDeviceState) -> Double {
        Double(blocksNeeded) / Double(max(1, capacityBlocks(on: state)))
    }

    /// "12 min over" for audio, "85 MB over" for data.
    public func overText(blocks: Int) -> String {
        switch type {
        case .audio:
            let minutes = Int((Double(blocks) / Double(Self.sectorsPerSecond) / 60).rounded(.up))
            return "\(minutes) min over"
        case .data, .video:
            let megabytes = Int((Double(blocks) * 2_048 / 1_048_576).rounded(.up))
            return "\(megabytes) MB over"
        }
    }

    /// "47 min of 80 min" for audio, "310 MB of 700 MB" for data.
    public func usedText(on state: BurnDeviceState) -> String {
        let capacity = capacityBlocks(on: state)
        switch type {
        case .audio:
            return "\(Int((Double(blocksNeeded) / Double(Self.sectorsPerSecond) / 60).rounded(.up))) min of \(capacity / Self.sectorsPerSecond / 60) min"
        case .data, .video:
            return "\(Int((Double(blocksNeeded) * 2_048 / 1_048_576).rounded(.up))) MB of \(capacity * 2_048 / 1_048_576) MB"
        }
    }
}

public struct BurnJob: Equatable, Sendable {
    public var type: DiscType
    /// In disc order.
    public var files: [URL]
    public var volumeName: String
    /// For an MP3 Disc: the folder each file goes in, one per file ("" is the top of the disc).
    public var placements: [String]
    /// For an MP3 Disc: every folder to make, empty ones too.
    public var folders: [String]

    public init(type: DiscType, files: [URL], volumeName: String, placements: [String] = [], folders: [String] = []) {
        self.type = type
        self.files = files
        self.volumeName = volumeName
        self.placements = placements
        self.folders = folders
    }
}

public enum BurnStage: Equatable, Sendable {
    /// Nothing is written yet. Cancel leaves the disc as it was.
    case preparing
    /// Writing has started. Stopping now ruins the disc.
    case burning(Double)
    case finishing
}

public enum BurnError: Error, Equatable, LocalizedError, Sendable {
    case noDisc
    case driveError(String)
    case discRejected(String)

    public var errorDescription: String? {
        switch self {
        case .noDisc: "There is no blank disc in the drive."
        case .driveError(let detail): "The drive reported an error. \(detail)"
        case .discRejected(let detail): "The disc was rejected. \(detail)"
        }
    }
}

/// A burner: a real drive through DiscRecording, or a stand-in for tests.
public protocol DiscBurner: Sendable {
    var deviceName: String? { get }
    func state() -> BurnDeviceState
    /// Emits a new state when the drive or disc changes.
    func stateChanges() -> AsyncStream<BurnDeviceState>
    /// Reports stages as they happen. Throws `CancellationError` if cancelled before writing starts.
    func burn(_ job: BurnJob, progress: @Sendable (BurnStage) -> Void) async throws
    func eject()
}
