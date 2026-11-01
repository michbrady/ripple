import Foundation

/// Folders and file names on an MP3 Disc. A folder is a path of names joined with "/": "" is the top of the disc,
/// "Rock" a folder, "Rock/Live" a folder inside it.
public enum DiscLayout {
    /// One file on the disc.
    public struct Entry: Equatable, Sendable {
        /// The file to put on the disc. For an M4A this is the original until `DiscPreparer` swaps in the MP3.
        public var source: URL
        public var folder: String
        public var name: String
        /// True when `source` is not MP3 and has to be converted first.
        public var needsConversion: Bool
    }

    public static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// 0 for a folder at the top, 1 for one inside it.
    public static func depth(of path: String) -> Int { path.split(separator: "/").count - 1 }

    /// `path` and every folder above it: "A/B" gives ["A", "A/B"].
    public static func withAncestors(_ path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for part in path.split(separator: "/") {
            current = join(current, String(part))
            result.append(current)
        }
        return result
    }

    /// Every folder that exists: the ones made by hand and the ones holding files, with their ancestors, in name order.
    public static func allFolders(items: [BurnItem], made: [String]) -> [String] {
        var all = Set<String>()
        for path in made + items.map(\.folder) { all.formUnion(withAncestors(path)) }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A folder name safe on the disc and not yet used inside `parent`.
    public static func newFolderName(_ wanted: String, in parent: String, existing: [String]) -> String {
        let taken = Set(existing.filter { Self.parent(of: $0) == parent }.map(Self.name(of:)))
        return FileNamer.unique(FileNamer.clean(wanted, maxBytes: 64, fallback: "Untitled Folder"), taken: taken)
    }

    /// The files in disc order with the names they get: `01 - Title.mp3`, numbered inside each folder.
    public static func entries(for job: BurnJob) -> [Entry] {
        func folder(_ index: Int) -> String { job.placements.indices.contains(index) ? job.placements[index] : "" }
        var totals: [String: Int] = [:]
        for index in job.files.indices { totals[folder(index), default: 0] += 1 }
        var next: [String: Int] = [:]
        return job.files.enumerated().map { index, file in
            let place = folder(index)
            next[place, default: 0] += 1
            let isMP3 = file.pathExtension.lowercased() == "mp3"
            let name = BurnNaming.discFileName(position: next[place]!, of: totals[place] ?? 0, original: file,
                                               fileExtension: isMP3 ? file.pathExtension : "mp3")
            return Entry(source: file, folder: place, name: name, needsConversion: !isMP3)
        }
    }
}

/// Gets the files of an MP3 Disc ready: every file that is not MP3 becomes an MP3 in a work folder.
public enum DiscPreparer {
    /// Returns the entries with converted files as their sources, and the work folder to delete after the burn
    /// (nil when nothing was converted). Throws `CancellationError` if the task is cancelled.
    public static func prepare(_ entries: [Entry]) async throws -> (entries: [Entry], workFolder: URL?) {
        guard entries.contains(where: \.needsConversion) else { return (entries, nil) }
        let work = FileManager.default.temporaryDirectory.appending(path: "Ripple-burn-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            var result = entries
            for index in result.indices where result[index].needsConversion {
                try Task.checkCancellation()
                let output = work.appending(path: "\(index).mp3")
                try await MP3Converter.convert(result[index].source, to: output)
                result[index].source = output
                result[index].needsConversion = false
            }
            return (result, work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    public typealias Entry = DiscLayout.Entry
}
