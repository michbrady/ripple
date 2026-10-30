import Foundation

public struct RipTrack: Equatable, Sendable {
    /// The track number on the disc.
    public var number: Int
    public var title: String
    public var artist: String
    public var include: Bool

    public init(number: Int, title: String, artist: String = "", include: Bool = true) {
        self.number = number
        self.title = title
        self.artist = artist
        self.include = include
    }
}

public struct RipRequest: Sendable {
    public var disc: any AudioDisc
    /// One per entry in the disc's table of contents, in order.
    public var tracks: [RipTrack]
    public var albumArtist: String
    public var album: String
    /// The Output Folder. Files land in `Artist/Album/` inside it.
    public var folder: URL
    public var quality: MP3Encoder.Quality
    public var format: RipFormat
    /// Which disc of a set this is. Sets of two or more discs get a `Disc N` folder.
    public var discNumber: Int
    public var discCount: Int
    /// Compilations put the track artist in each file name.
    public var isCompilation: Bool

    public init(disc: any AudioDisc, tracks: [RipTrack], albumArtist: String, album: String,
                folder: URL, quality: MP3Encoder.Quality = .vbr(2), format: RipFormat = .mp3,
                discNumber: Int = 1, discCount: Int = 1, isCompilation: Bool = false) {
        self.format = format
        self.discNumber = discNumber
        self.discCount = discCount
        self.isCompilation = isCompilation
        self.disc = disc
        self.tracks = tracks
        self.albumArtist = albumArtist
        self.album = album
        self.folder = folder
        self.quality = quality
    }
}

public enum RipEvent: Sendable, Equatable {
    case started(track: Int)
    /// 0 to 1, for the track with this index in the table of contents.
    case progress(track: Int, fraction: Double)
    case finished(track: Int, file: URL)
}

/// Copies tracks from a disc to MP3 or M4A files.
public enum Ripper {
    /// Sectors per read: about a third of a second of sound.
    static let chunkSectors = 26

    /// Rips every included audio track. Run it off the main thread inside a Task:
    /// it checks for cancellation between reads. On cancel or error the track in
    /// progress is deleted and finished tracks stay.
    public static func rip(_ request: RipRequest, onEvent: @Sendable (RipEvent) -> Void) async throws -> [URL] {
        let toc = request.disc.toc
        let fm = FileManager.default
        var albumDir = request.folder
            .appending(path: FileNamer.clean(request.albumArtist, fallback: "Unknown Artist"), directoryHint: .isDirectory)
            .appending(path: FileNamer.clean(request.album, fallback: "Unknown Album"), directoryHint: .isDirectory)
        if request.discCount > 1 {
            albumDir = albumDir.appending(path: "Disc \(request.discNumber)", directoryHint: .isDirectory)
        }
        try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)
        defer { removeIfEmpty(albumDir) }

        var taken = Set((try? fm.contentsOfDirectory(atPath: albumDir.path)) ?? [])
        var files: [URL] = []

        for (index, entry) in toc.entries.enumerated() where entry.isAudio {
            guard index < request.tracks.count, request.tracks[index].include else { continue }
            if Task.isCancelled { throw CancellationError() }
            let track = request.tracks[index]
            let name = FileNamer.unique(
                FileNamer.trackFileName(number: entry.number, title: track.title, fileExtension: request.format.fileExtension,
                                        trackCount: toc.trackCount, artist: request.isCompilation ? track.artist : nil),
                taken: taken)
            taken.insert(name)
            onEvent(.started(track: index))
            let file = albumDir.appending(path: name)
            try await ripTrack(index: index, request: request, to: file, onEvent: onEvent)
            files.append(file)
            onEvent(.finished(track: index, file: file))
        }
        return files
    }

    private static func ripTrack(index: Int, request: RipRequest, to file: URL,
                                 onEvent: @Sendable (RipEvent) -> Void) async throws {
        let fm = FileManager.default
        let ext = request.format.fileExtension
        let partial = file.deletingLastPathComponent().appending(path: ".ripple-\(UUID().uuidString).partial.\(ext)")
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: partial) } }

        let writer: any TrackWriter
        switch request.format {
        case .mp3: writer = try MP3TrackWriter(url: partial, quality: request.quality)
        case .m4a: writer = try M4ATrackWriter(url: partial)
        }
        let sectors = request.disc.toc.sectors(ofTrack: index)
        var position = sectors.lowerBound
        while position < sectors.upperBound {
            if Task.isCancelled { throw CancellationError() }
            let count = min(chunkSectors, sectors.upperBound - position)
            try writer.write(try request.disc.readSectors(start: position, count: count))
            position += count
            onEvent(.progress(track: index, fraction: Double(position - sectors.lowerBound) / Double(max(1, sectors.count))))
        }
        try await writer.finish()
        try fm.moveItem(at: partial, to: file)
        succeeded = true
    }

    /// Removes an album folder (and its artist folder) when a cancelled rip left nothing in them.
    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        for folder in [dir, dir.deletingLastPathComponent()] {
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["."]
            if contents.allSatisfy({ $0.hasPrefix(".ripple-") }) { try? fm.removeItem(at: folder) } else { return }
        }
    }
}
