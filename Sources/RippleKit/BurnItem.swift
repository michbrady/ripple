import AVFoundation
import Foundation

/// One MP3 file in the burn list.
public struct BurnItem: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var title: String
    public var artist: String
    public var seconds: Double
    public var bytes: Int
    /// From the file's tags; nil when it has none.
    public var trackNumber: Int?

    public init(url: URL, title: String, artist: String = "", seconds: Double, bytes: Int, trackNumber: Int? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
        self.seconds = seconds
        self.bytes = bytes
        self.trackNumber = trackNumber
    }
}

/// The MP3 files found in a folder, and how many other files were left out.
public struct BurnScan: Equatable, Sendable {
    public var items: [BurnItem]
    public var skipped: Int
}

public enum BurnScanner {
    /// Finds every MP3 under `folder` (subfolders included). Order: folder, then track number from the tags,
    /// then file name. A file with no title tag uses its file name. Hidden files and folders are ignored.
    /// Files that are not MP3 count as skipped.
    public static func scan(_ folder: URL) async -> BurnScan {
        let urls = enumerate(folder)
        return await scan(files: urls.mp3, skipped: urls.other, root: folder)
    }

    /// For files and folders dropped on the window.
    public static func scan(dropped urls: [URL]) async -> BurnScan {
        var mp3: [URL] = []
        var other = 0
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                let found = enumerate(url)
                mp3 += found.mp3
                other += found.other
            } else if url.pathExtension.lowercased() == "mp3" {
                mp3.append(url)
            } else if !url.lastPathComponent.hasPrefix(".") {
                other += 1
            }
        }
        return await scan(files: mp3, skipped: other, root: urls.count == 1 ? urls[0].deletingLastPathComponent() : nil)
    }

    private static func enumerate(_ folder: URL) -> (mp3: [URL], other: Int) {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], 0) }
        var mp3: [URL] = []
        var other = 0
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if url.pathExtension.lowercased() == "mp3" { mp3.append(url) } else { other += 1 }
        }
        return (mp3, other)
    }

    private static func scan(files: [URL], skipped: Int, root: URL?) async -> BurnScan {
        var items: [BurnItem] = []
        for url in files {
            if let item = await read(url) { items.append(item) }
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
        func string(_ id: AVMetadataIdentifier) async -> String? {
            let text = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first?.load(.stringValue)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let title = await string(.id3MetadataTitleDescription)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await string(.id3MetadataLeadPerformer) ?? ""
        let track = await string(.id3MetadataTrackNumber).flatMap { Int($0.split(separator: "/").first ?? "") }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return BurnItem(url: url, title: title, artist: artist, seconds: duration.seconds, bytes: bytes, trackNumber: track)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
