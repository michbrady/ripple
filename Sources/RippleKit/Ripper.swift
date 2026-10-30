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

    public init(disc: any AudioDisc, tracks: [RipTrack], albumArtist: String, album: String,
                folder: URL, quality: MP3Encoder.Quality = .vbr(2)) {
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

/// Copies tracks from a disc to MP3 files.
public enum Ripper {
    /// Sectors per read: about a third of a second of sound.
    static let chunkSectors = 26

    /// Rips every included audio track. Run it off the main thread inside a Task:
    /// it checks for cancellation between reads. On cancel or error the track in
    /// progress is deleted and finished tracks stay.
    public static func rip(_ request: RipRequest, onEvent: @Sendable (RipEvent) -> Void) throws -> [URL] {
        let toc = request.disc.toc
        let fm = FileManager.default
        let albumDir = request.folder
            .appending(path: FileNamer.clean(request.albumArtist, fallback: "Unknown Artist"), directoryHint: .isDirectory)
            .appending(path: FileNamer.clean(request.album, fallback: "Unknown Album"), directoryHint: .isDirectory)
        try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)
        defer { removeIfEmpty(albumDir) }

        var taken = Set((try? fm.contentsOfDirectory(atPath: albumDir.path)) ?? [])
        var files: [URL] = []

        for (index, entry) in toc.entries.enumerated() where entry.isAudio {
            guard index < request.tracks.count, request.tracks[index].include else { continue }
            if Task.isCancelled { throw CancellationError() }
            let track = request.tracks[index]
            let name = FileNamer.unique(
                FileNamer.trackFileName(number: entry.number, title: track.title, fileExtension: "mp3", trackCount: toc.trackCount),
                taken: taken)
            taken.insert(name)
            onEvent(.started(track: index))
            let file = albumDir.appending(path: name)
            try ripTrack(index: index, request: request, to: file, onEvent: onEvent)
            files.append(file)
            onEvent(.finished(track: index, file: file))
        }
        return files
    }

    private static func ripTrack(index: Int, request: RipRequest, to file: URL,
                                 onEvent: @Sendable (RipEvent) -> Void) throws {
        let fm = FileManager.default
        let partial = file.deletingLastPathComponent().appending(path: ".ripple-\(UUID().uuidString).partial")
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: partial.path])
        }
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: partial) } }

        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let encoder = try MP3Encoder(quality: request.quality)
        let sectors = request.disc.toc.sectors(ofTrack: index)
        var position = sectors.lowerBound
        while position < sectors.upperBound {
            if Task.isCancelled { throw CancellationError() }
            let count = min(chunkSectors, sectors.upperBound - position)
            let pcm = try request.disc.readSectors(start: position, count: count)
            try handle.write(contentsOf: try encoder.encode(pcm))
            position += count
            onEvent(.progress(track: index, fraction: Double(position - sectors.lowerBound) / Double(max(1, sectors.count))))
        }
        let (tail, tag) = try encoder.finish()
        try handle.write(contentsOf: tail)
        if !tag.isEmpty {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag)
        }
        try handle.close()
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
