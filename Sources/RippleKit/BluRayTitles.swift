import Foundation

/// Turns the one-title disc tsMuxeR writes into a disc with a title for each video as well as one that plays everything.
///
/// tsMuxeR writes one stream (`00000.m2ts`) holding every video, one playlist that plays it all with a chapter for each video, and
/// the two files that say what the disc does when it loads: `index.bdmv` (the list of titles) and `MovieObject.bdmv` (what each title
/// runs). This adds one playlist per video that plays just that video's part of the same stream, and one title for each. Nothing is stored
/// twice. Every new piece is a copy of tsMuxeR's own with only numbers changed, and `bd_list_titles` (libbluray) reads the result.
public enum BluRayTitles {
    public enum Problem: Error, Equatable, Sendable { case unexpectedFile(String) }

    /// Playlist times are in ticks of a 45 kHz clock.
    static let ticks = 45_000.0

    static func be32(_ d: Data, _ at: Int) -> Int { d.subdata(in: at..<at + 4).reduce(0) { $0 << 8 | Int($1) } }
    static func bytes(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * (count - 1 - $0))) & 0xFF) } }

    // MARK: Playlists (.mpls)

    /// Where the play item's start and end times sit, and where the chapter marks begin.
    struct PlaylistSpec { var inTime: Int, outTime: Int, inAt: Int, markStart: Int, markTemplate: [UInt8] }

    static func read(playlist d: Data) throws -> PlaylistSpec {
        guard d.count > 60, String(decoding: d.prefix(4), as: UTF8.self) == "MPLS" else { throw Problem.unexpectedFile("playlist") }
        let listStart = be32(d, 8), markStart = be32(d, 12)
        let inAt = listStart + 24
        guard markStart + 6 + 14 <= d.count, inAt + 8 <= markStart else { throw Problem.unexpectedFile("playlist") }
        return PlaylistSpec(inTime: be32(d, inAt), outTime: be32(d, inAt + 4), inAt: inAt, markStart: markStart,
                            markTemplate: Array(d.subdata(in: markStart + 6..<markStart + 20)))
    }

    /// The chapter marks section: one mark at each of `times` (in clock ticks).
    static func marks(_ times: [Int], like template: [UInt8]) -> Data {
        var out = Data(bytes(2 + 14 * times.count, 4) + bytes(times.count, 2))
        for time in times {
            var mark = template
            mark.replaceSubrange(4..<8, with: bytes(time, 4))
            out.append(contentsOf: mark)
        }
        return out
    }

    /// `template` with its chapters at `starts` (seconds from the start of the program), and if `end` is given, playing only up to it.
    /// With `from`, playing starts there instead of at the start.
    public static func playlist(from template: Data, chapters starts: [Double], from start: Double? = nil, to end: Double? = nil) throws -> Data {
        let spec = try read(playlist: template)
        var d = template
        let base = spec.inTime
        if let start { d.replaceSubrange(spec.inAt..<spec.inAt + 4, with: bytes(base + Int((start * ticks).rounded()), 4)) }
        if let end { d.replaceSubrange(spec.inAt + 4..<spec.inAt + 8, with: bytes(base + Int((end * ticks).rounded()), 4)) }
        let tail = d.subdata(in: spec.markStart..<d.count)
        let oldMarks = 4 + be32(tail, 0)
        d.replaceSubrange(spec.markStart..<d.count, with: marks(starts.map { base + Int(($0 * ticks).rounded()) }, like: spec.markTemplate)
                          + tail.subdata(in: min(oldMarks, tail.count)..<tail.count))
        return d
    }

    // MARK: index.bdmv and MovieObject.bdmv

    /// The list of titles: the first title is "play everything", then one for each video. `Object ids`: titles 0 to `titles - 1`,
    /// then the top menu, then what runs when the disc loads, the same order tsMuxeR uses.
    public static func index(from template: Data, titles: Int) throws -> Data {
        guard template.count >= 120, String(decoding: template.prefix(4), as: UTF8.self) == "INDX" else { throw Problem.unexpectedFile("index") }
        let start = be32(template, 8)
        let section = template.subdata(in: start..<template.count)
        let oldLength = be32(section, 0)
        guard section.count >= 4 + 12 + 12 + 2 + 12, 4 + oldLength <= section.count else { throw Problem.unexpectedFile("index") }
        func entry(_ at: Int, id: Int) -> Data { var e = Data(section.subdata(in: at..<at + 12)); e.replaceSubrange(6..<8, with: bytes(id, 2)); return e }
        var body = entry(4, id: titles + 1) + entry(16, id: titles) + Data(bytes(titles, 2))   // first playback, top menu, count
        for title in 0..<titles { body += entry(30, id: title) }
        return template.subdata(in: 0..<start) + Data(bytes(body.count, 4)) + body + section.subdata(in: 4 + oldLength..<section.count)
    }

    /// What each title runs. Title `k` is tsMuxeR's own "play the playlist" object with the playlist number set to `k`.
    public static func movieObjects(from template: Data, titles: Int) throws -> Data {
        guard template.count > 0x32, String(decoding: template.prefix(4), as: UTF8.self) == "MOBJ" else { throw Problem.unexpectedFile("movie objects") }
        let count = Int(template[0x30]) << 8 | Int(template[0x31])
        var objects: [Data] = [], at = 0x32
        for _ in 0..<count {
            guard at + 4 <= template.count else { throw Problem.unexpectedFile("movie objects") }
            let commands = Int(template[at + 2]) << 8 | Int(template[at + 3])
            let end = at + 4 + 12 * commands
            guard count == 3, end <= template.count else { throw Problem.unexpectedFile("movie objects") }
            objects.append(template.subdata(in: at..<end)); at = end
        }
        // Object 0 is the title that plays playlist 0: its fourth command is the one that starts the playlist, with the number in its first operand.
        let play = 4 + 12 * 3
        guard objects[0].count >= play + 12, objects[0][play] == 0x42 else { throw Problem.unexpectedFile("movie objects") }
        var all: [Data] = []
        for k in 0..<titles {
            var object = objects[0]
            object.replaceSubrange(play + 4..<play + 8, with: bytes(k, 4))
            all.append(object)
        }
        all += [objects[1], objects[2]]
        let body = Data(bytes(0, 4) + bytes(all.count, 2)) + all.reduce(Data()) { $0 + $1 }
        return template.subdata(in: 0..<0x28) + Data(bytes(body.count, 4)) + body
    }

    // MARK: The disc folder

    /// Rewrites a tsMuxeR disc folder (the one holding `BDMV`) so it has a title for each video after the title that plays everything.
    /// `lengths` is how long each video is, in seconds, in disc order. Does nothing for fewer than two videos.
    public static func addTitles(to disc: URL, lengths: [Double]) throws {
        guard lengths.count > 1 else { return }
        let fm = FileManager.default
        let bdmv = disc.appending(path: "BDMV")
        let first = try Data(contentsOf: bdmv.appending(path: "PLAYLIST/00000.mpls"))
        let spec = try read(playlist: first)
        var starts = [0.0]
        for length in lengths.dropLast() { starts.append(starts.last! + length) }
        let total = lengths.reduce(0, +)
        let index = try index(from: Data(contentsOf: bdmv.appending(path: "index.bdmv")), titles: lengths.count + 1)
        let objects = try movieObjects(from: Data(contentsOf: bdmv.appending(path: "MovieObject.bdmv")), titles: lengths.count + 1)

        var files: [(String, Data)] = [("PLAYLIST/00000.mpls", try playlist(from: first, chapters: starts, to: nil))]
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : max(total, Double(spec.outTime - spec.inTime) / ticks)
            files.append((String(format: "PLAYLIST/%05d.mpls", k + 1), try playlist(from: first, chapters: [start], from: start, to: end)))
        }
        files += [("index.bdmv", index), ("MovieObject.bdmv", objects)]
        // The disc keeps a second copy of these files in BACKUP; a player falls back to it when the first is damaged, so both must agree.
        for (name, data) in files {
            for folder in [bdmv, bdmv.appending(path: "BACKUP")] where fm.fileExists(atPath: folder.path) {
                let url = folder.appending(path: name)
                try? fm.removeItem(at: url)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
    }
}
