import AVFoundation
import Foundation

/// One MP3 or M4A file in the burn list.
public struct BurnItem: Identifiable, Equatable, Sendable {
    /// The file's real path, so the same file reached through a link (/tmp and /private/tmp) is one item.
    public let id: String
    public var url: URL
    public var title: String
    public var artist: String
    public var seconds: Double
    public var bytes: Int
    /// From the file's tags; nil when it has none.
    public var trackNumber: Int?
    /// The folder it goes in on an MP3 Disc: "" for the top, "Rock" or "Rock/Live" for a folder. An Audio CD has no folders.
    public var folder: String

    /// An M4A file on an MP3 Disc is converted to MP3 at 192 kbps, which is this many bytes per second.
    public static let convertedBytesPerSecond = 24_000

    public init(url: URL, title: String, artist: String = "", seconds: Double, bytes: Int, trackNumber: Int? = nil, folder: String = "") {
        self.id = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.url = url
        self.title = title
        self.artist = artist
        self.seconds = seconds
        self.bytes = bytes
        self.trackNumber = trackNumber
        self.folder = folder
    }

    public var isMP3: Bool { url.pathExtension.lowercased() == "mp3" }

    /// Bytes the file takes on an MP3 Disc: its own size, or the estimated size once converted to MP3.
    public var discBytes: Int { isMP3 ? bytes : Int(seconds * Double(Self.convertedBytesPerSecond)) }
}

/// The MP3 files found in a folder, and how many other files were left out.
public struct BurnScan: Equatable, Sendable {
    public var items: [BurnItem]
    public var skipped: Int
}

public enum BurnScanner {
    /// The kinds of file that can be burned.
    public static let extensions: Set<String> = ["mp3", "m4a"]

    static func isMusic(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Finds every MP3 and M4A under `folder` (subfolders included). Order: folder, then track number from the tags,
    /// then file name. A file with no title tag uses its file name. Hidden files and folders are ignored.
    /// Other files count as skipped. Each item's `folder` is its subfolder path inside `folder`.
    public static func scan(_ folder: URL) async -> BurnScan {
        let found = enumerate(folder, relativeTo: folder)
        return await scan(files: found.music, skipped: found.other)
    }

    /// For files and folders dropped on the window. A dropped folder keeps its name as a folder on the disc.
    public static func scan(dropped urls: [URL]) async -> BurnScan {
        var music: [(URL, String)] = []
        var other = 0
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                let found = enumerate(url, relativeTo: url.deletingLastPathComponent())
                music += found.music
                other += found.other
            } else if isMusic(url) {
                music.append((url, ""))
            } else if !url.lastPathComponent.hasPrefix(".") {
                other += 1
            }
        }
        return await scan(files: music, skipped: other)
    }

    /// The folders between `root` and the file, cleaned to safe names and joined with "/".
    static func relativeFolder(of url: URL, from root: URL) -> String {
        // /var and /private/var are the same place, so compare real paths.
        let base = root.resolvingSymlinksInPath().pathComponents
        let parts = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return "" }
        return parts.dropFirst(base.count).map { FileNamer.clean($0, maxBytes: 64) }.joined(separator: "/")
    }

    private static func enumerate(_ folder: URL, relativeTo root: URL) -> (music: [(URL, String)], other: Int) {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], 0) }
        var music: [(URL, String)] = []
        var other = 0
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if isMusic(url) { music.append((url, relativeFolder(of: url, from: root))) } else { other += 1 }
        }
        return (music, other)
    }

    private static func scan(files: [(URL, String)], skipped: Int) async -> BurnScan {
        var items: [BurnItem] = []
        for (url, folder) in files {
            if var item = await read(url) {
                item.folder = folder
                items.append(item)
            }
        }
        items.sort { a, b in
            let folderA = a.url.deletingLastPathComponent().path
            let folderB = b.url.deletingLastPathComponent().path
            if folderA != folderB { return folderA.localizedStandardCompare(folderB) == .orderedAscending }
            switch (a.trackNumber, b.trackNumber) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }
        return BurnScan(items: items, skipped: skipped + (files.count - items.count))
    }

    /// Title, artist, length, and size of one file. Nil when AVFoundation cannot read it as audio.
    public static func read(_ url: URL) async -> BurnItem? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let metadata = (try? await asset.load(.metadata)) ?? []
        func string(_ ids: [AVMetadataIdentifier]) async -> String? {
            for id in ids {
                let text = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first?.load(.stringValue)
                if let value = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return value }
            }
            return nil
        }
        let title = await string([.id3MetadataTitleDescription, .iTunesMetadataSongName, .commonIdentifierTitle])
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await string([.id3MetadataLeadPerformer, .iTunesMetadataArtist, .commonIdentifierArtist]) ?? ""
        var track = await string([.id3MetadataTrackNumber]).flatMap { Int($0.split(separator: "/").first ?? "") }
        if track == nil,
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataTrackNumber).first {
            // MP4 stores "trkn" as 8 bytes: two zero bytes, then the track number as 16 bits.
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                track = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
            } else if let number = try? await item.load(.numberValue) {
                track = number.intValue
            }
        }
        if track == 0 { track = nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return BurnItem(url: url, title: title, artist: artist, seconds: duration.seconds, bytes: bytes, trackNumber: track)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
