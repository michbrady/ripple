import Foundation

/// Puts the files of a Video DVD image in the order a DVD player reads them.
///
/// A DVD player finds the video by arithmetic, not by name. Each `.IFO` file says where its menu and its video start, counted in
/// sectors from the start of the `.IFO` itself (for example "6 sectors after me"). That only works when each group sits together in
/// this order: `VIDEO_TS.IFO`, `VIDEO_TS.VOB`, `VIDEO_TS.BUP`, then for each title set `VTS_nn_0.IFO`, `VTS_nn_0.VOB`, `VTS_nn_1.VOB`
/// and on, `VTS_nn_0.BUP`. A computer opens files by name and does not notice, but many standalone players do.
///
/// `hdiutil makehybrid` lays the files out in an order of its own that cannot be changed, so this rewrites the finished image:
/// it moves the files of the VIDEO_TS folder into the right order, fixes the two places that say where each file is (the ISO 9660
/// folder records and the UDF file entries), and checks the result. Any surprise throws, and the caller keeps the original image.
public enum DVDImageOrder {
    public enum Problem: Error, Equatable, Sendable { case unexpected(String) }

    static let sector = 2_048

    // MARK: The order

    /// The names, in the order they belong on the disc. Names such as `VTS_01_1.VOB` may carry a `;1` version from ISO 9660.
    public static func order(_ names: [String]) -> [String] {
        func key(_ name: String) -> (Int, Int, Int, String) {
            let clean = name.split(separator: ";").first.map(String.init)?.uppercased() ?? name.uppercased()
            let ext = clean.split(separator: ".").last.map(String.init) ?? ""
            if clean.hasPrefix("VIDEO_TS.") {
                return (0, ["IFO": 0, "VOB": 1, "BUP": 9][ext] ?? 5, 0, clean)
            }
            let parts = clean.split(whereSeparator: { $0 == "_" || $0 == "." }).map(String.init)   // VTS, 01, 1, VOB
            if parts.count == 4, parts[0] == "VTS", let set = Int(parts[1]), let part = Int(parts[2]) {
                switch ext {
                case "IFO": return (set, 0, part, clean)
                case "VOB": return (set, part == 0 ? 1 : 2, part, clean)
                case "BUP": return (set, 9, part, clean)
                default: break
                }
            }
            return (10_000, 5, 0, clean)
        }
        return names.sorted { key($0) < key($1) }
    }

    // MARK: The image

    /// One file of the VIDEO_TS folder, as the ISO 9660 side lists it.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var lba: Int
        public var size: Int
        /// Where the folder record for this file sits in the image, so its location can be rewritten.
        var recordSector: Int
        var recordOffset: Int
        public var sectors: Int { (size + sector - 1) / sector }
    }

    /// The files of VIDEO_TS in the order they are on the disc.
    public static func listing(of image: URL) throws -> [Entry] {
        let file = try FileHandle(forReadingFrom: image)
        defer { try? file.close() }
        return try listing(file)
    }

    private static func read(_ file: FileHandle, sector index: Int, count: Int = 1) throws -> [UInt8] {
        try file.seek(toOffset: UInt64(index) * UInt64(sector))
        let data = try file.read(upToCount: count * sector) ?? Data()
        guard data.count == count * sector else { throw Problem.unexpected("image ends early") }
        return [UInt8](data)
    }

    private static func le32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
    private static func le16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }

    /// The records of one ISO 9660 folder.
    private static func records(_ file: FileHandle, lba: Int, size: Int) throws -> [(name: String, lba: Int, size: Int, flags: UInt8, sector: Int, offset: Int)] {
        let count = (size + sector - 1) / sector
        let data = try read(file, sector: lba, count: count)
        var out: [(String, Int, Int, UInt8, Int, Int)] = []
        var at = 0
        while at < data.count {
            let length = Int(data[at])
            if length == 0 { at = (at / sector + 1) * sector; continue }
            guard at + length <= data.count, length >= 34 else { throw Problem.unexpected("folder record") }
            let nameLength = Int(data[at + 32])
            guard 33 + nameLength <= length else { throw Problem.unexpected("folder record name") }
            let nameBytes = Array(data[(at + 33)..<(at + 33 + nameLength)])
            let name = nameBytes == [0] ? "." : nameBytes == [1] ? ".." : String(decoding: nameBytes, as: UTF8.self)
            out.append((name, le32(data, at + 2), le32(data, at + 10), data[at + 25], lba + at / sector, at % sector))
            at += length
        }
        return out
    }

    private static func listing(_ file: FileHandle) throws -> [Entry] {
        let pvd = try read(file, sector: 16)
        guard Array(pvd[1..<6]) == Array("CD001".utf8) else { throw Problem.unexpected("no ISO 9660 volume") }
        let root = try records(file, lba: le32(pvd, 158), size: le32(pvd, 166))
        guard let folder = root.first(where: { $0.flags & 2 != 0 && $0.name.uppercased() == "VIDEO_TS" }) else { throw Problem.unexpected("no VIDEO_TS folder") }
        var entries: [Entry] = []
        for record in try records(file, lba: folder.lba, size: folder.size) where record.name != "." && record.name != ".." && record.flags & 2 == 0 {
            guard record.flags & 0x80 == 0 else { throw Problem.unexpected("a file in several pieces") }
            entries.append(Entry(name: record.name, lba: record.lba, size: record.size, recordSector: record.sector, recordOffset: record.offset))
        }
        return entries.sorted { $0.lba < $1.lba }
    }

    /// Checks the arithmetic a player does: for each `.IFO`, the menu and the video it points to must be where it says, counted in
    /// sectors from the start of the `.IFO`, and its "last sector" must reach the end of its `.BUP`. Returns what is wrong, or nothing.
    public static func addressingProblems(in image: URL) throws -> [String] {
        let entries = try listing(of: image)
        let file = try FileHandle(forReadingFrom: image)
        defer { try? file.close() }
        func entry(_ name: String) -> Entry? { entries.first { $0.name.split(separator: ";").first.map { $0.uppercased() == name } ?? false } }
        func be32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
        var problems: [String] = []

        func check(group: String, ifo: String, menu: String, titles: [String], bup: String, menuField: Int, titleField: Int?) throws {
            guard let info = entry(ifo), let backup = entry(bup) else { problems.append("\(group): no \(ifo) or \(bup)"); return }
            let header = try read(file, sector: info.lba)
            if let vob = entry(menu) {
                if info.lba + be32(header, menuField) != vob.lba { problems.append("\(ifo) says its menu starts \(be32(header, menuField)) sectors after it, but \(menu) is \(vob.lba - info.lba) after") }
            }
            if let titleField, let first = titles.compactMap(entry).first {
                if info.lba + be32(header, titleField) != first.lba { problems.append("\(ifo) says its video starts \(be32(header, titleField)) sectors after it, but \(first.name) is \(first.lba - info.lba) after") }
            }
            // dvdauthor writes an unrelated "last sector" for a main menu that has no video (it says 31 for 6 sectors), and players cope.
            let hasMenu = entry(menu) != nil
            if (hasMenu || group != "VIDEO_TS"), info.lba + be32(header, 0x0C) + 1 != backup.lba + backup.sectors { problems.append("\(ifo) says the set ends \(be32(header, 0x0C)) sectors after it, but \(bup) ends \(backup.lba + backup.sectors - 1 - info.lba) after") }
            for (a, b) in zip(titles.compactMap(entry), titles.compactMap(entry).dropFirst()) where a.lba + a.sectors != b.lba { problems.append("\(b.name) does not follow \(a.name)") }
        }
        try check(group: "VIDEO_TS", ifo: "VIDEO_TS.IFO", menu: "VIDEO_TS.VOB", titles: [], bup: "VIDEO_TS.BUP", menuField: 0xC0, titleField: nil)
        let sets = Set(entries.compactMap { entry -> Int? in
            let parts = entry.name.uppercased().split(whereSeparator: { $0 == "_" || $0 == "." || $0 == ";" }).map(String.init)
            return parts.count >= 3 && parts[0] == "VTS" ? Int(parts[1]) : nil
        }).sorted()
        for number in sets {
            let tag = String(format: "VTS_%02d", number)
            let titles = (1...9).map { "\(tag)_\($0).VOB" }
            try check(group: tag, ifo: "\(tag)_0.IFO", menu: "\(tag)_0.VOB", titles: titles, bup: "\(tag)_0.BUP", menuField: 0xC0, titleField: 0xC4)
        }
        return problems
    }

    // MARK: UDF

    /// The checksum and CRC every UDF descriptor starts with, redone after its contents change.
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    private static func sealTag(_ block: inout [UInt8]) throws {
        let crcLength = le16(block, 10)
        guard 16 + crcLength <= block.count else { throw Problem.unexpected("descriptor length") }
        let crc = crc16(block[16..<(16 + crcLength)])
        block[8] = UInt8(crc & 0xFF); block[9] = UInt8(crc >> 8)
        var sum = 0
        for index in 0..<16 where index != 4 { sum += Int(block[index]) }
        block[4] = UInt8(sum & 0xFF)
    }

    private static func tagIsValid(_ block: [UInt8]) -> Bool {
        let crcLength = le16(block, 10)
        guard 16 + crcLength <= block.count else { return false }
        let crc = crc16(block[16..<(16 + crcLength)])
        var sum = 0
        for index in 0..<16 where index != 4 { sum += Int(block[index]) }
        return Int(block[8]) | Int(block[9]) << 8 == Int(crc) && block[4] == UInt8(sum & 0xFF)
    }

    /// A UDF file entry that holds a regular file: where its sector is, and where each piece of the file starts.
    struct FileEntry {
        var sector: Int
        var block: [UInt8]
        var extents: [(position: Int, length: Int, at: Int)]   // position counted from the partition start; `at` is the byte offset of the descriptor
    }

    /// The partition start, and the regular-file entries found before `before`, or nil for an image with no UDF.
    private static func udf(_ file: FileHandle, before: Int) throws -> (start: Int, entries: [FileEntry])? {
        let anchor = try read(file, sector: 256)
        guard le16(anchor, 0) == 2 else { return nil }
        let length = le32(anchor, 16), location = le32(anchor, 20)
        var start: Int?
        for index in 0..<max(1, length / sector) {
            let block = try read(file, sector: location + index)
            if le16(block, 0) == 5 { start = le32(block, 188); break }
            if le16(block, 0) == 8 { break }
        }
        guard let partition = start, partition < before else { throw Problem.unexpected("UDF partition") }
        var entries: [FileEntry] = []
        for index in partition..<before {
            let block = try read(file, sector: index)
            guard le16(block, 0) == 261, le32(block, 12) == index - partition, block[27] == 5 else { continue }
            guard le16(block, 34) & 7 == 0 else { throw Problem.unexpected("UDF file stored a way this does not handle") }
            guard tagIsValid(block) else { throw Problem.unexpected("UDF file entry checksum") }
            let extendedLength = le32(block, 168), descriptorLength = le32(block, 172)
            var extents: [(Int, Int, Int)] = []
            var at = 176 + extendedLength
            guard at + descriptorLength <= block.count, descriptorLength % 8 == 0 else { throw Problem.unexpected("UDF file entry layout") }
            while at < 176 + extendedLength + descriptorLength {
                extents.append((le32(block, at + 4), le32(block, at) & 0x3FFF_FFFF, at))
                at += 8
            }
            entries.append(FileEntry(sector: index, block: block, extents: extents))
        }
        return (partition, entries)
    }

    // MARK: Reordering

    /// Rewrites `image` with the VIDEO_TS files in DVD order. Returns false when it was already right.
    /// Throws when the image is not what this expects; the image is then left untouched.
    @discardableResult
    public static func reorder(image: URL) throws -> Bool {
        let fm = FileManager.default
        let temp = image.deletingLastPathComponent().appending(path: image.lastPathComponent + ".ordering")
        try? fm.removeItem(at: temp)
        defer { try? fm.removeItem(at: temp) }
        let changed = try rewrite(image, to: temp)
        guard changed else { return false }
        _ = try fm.replaceItemAt(image, withItemAt: temp)
        return true
    }

    private static func rewrite(_ image: URL, to temp: URL) throws -> Bool {
        let source = try FileHandle(forReadingFrom: image)
        defer { try? source.close() }
        let entries = try listing(source)
        guard !entries.isEmpty else { return false }
        // The files must fill one block of the image with no gaps, so moving them around leaves nothing stranded.
        for (before, after) in zip(entries, entries.dropFirst()) where before.lba + before.sectors != after.lba {
            throw Problem.unexpected("the files are not side by side")
        }
        guard entries.allSatisfy({ $0.size > 0 }) else { throw Problem.unexpected("an empty file") }
        let wanted = order(entries.map(\.name))
        if wanted == entries.map(\.name) { return false }

        let regionStart = entries[0].lba
        let regionEnd = entries.last!.lba + entries.last!.sectors
        var newLBA: [String: Int] = [:]
        var cursor = regionStart
        for name in wanted {
            guard let entry = entries.first(where: { $0.name == name }) else { throw Problem.unexpected("lost a file") }
            newLBA[name] = cursor
            cursor += entry.sectors
        }

        // The ISO 9660 folder records: each file's new location, written in both byte orders.
        var patched: [Int: [UInt8]] = [:]
        for entry in entries {
            var block = try patched[entry.recordSector] ?? read(source, sector: entry.recordSector)
            let new = newLBA[entry.name]!
            for shift in 0..<4 {
                block[entry.recordOffset + 2 + shift] = UInt8((new >> (8 * shift)) & 0xFF)
                block[entry.recordOffset + 9 - shift] = UInt8((new >> (8 * shift)) & 0xFF)
            }
            patched[entry.recordSector] = block
        }

        // The UDF file entries: every piece of every file moves by the same amount as its file.
        if let (partition, fileEntries) = try udf(source, before: regionStart) {
            var matched = Set<String>()
            for var fe in fileEntries {
                for extent in fe.extents {
                    let absolute = partition + extent.position
                    guard let owner = entries.first(where: { absolute >= $0.lba && absolute < $0.lba + $0.sectors }) else { continue }
                    let moved = extent.position + newLBA[owner.name]! - owner.lba
                    for shift in 0..<4 { fe.block[extent.at + 4 + shift] = UInt8((moved >> (8 * shift)) & 0xFF) }
                    matched.insert(owner.name)
                }
                try sealTag(&fe.block)
                patched[fe.sector] = fe.block
            }
            guard matched.count == entries.count else { throw Problem.unexpected("a file with no UDF entry") }
        }

        // Write the new image: the start as it was, the files in their new order, the end as it was.
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let out = try FileHandle(forWritingTo: temp)
        defer { try? out.close() }
        func copy(from offset: UInt64, count: UInt64) throws {
            try source.seek(toOffset: offset)
            var left = count
            while left > 0 {
                let chunk = try source.read(upToCount: Int(min(left, 4 << 20))) ?? Data()
                guard !chunk.isEmpty else { throw Problem.unexpected("image ends early") }
                try out.write(contentsOf: chunk)
                left -= UInt64(chunk.count)
            }
        }
        let unit = UInt64(sector)
        try copy(from: 0, count: UInt64(regionStart) * unit)
        for name in wanted {
            let entry = entries.first { $0.name == name }!
            try copy(from: UInt64(entry.lba) * unit, count: UInt64(entry.sectors) * unit)
        }
        let end = try source.seekToEnd()
        try copy(from: UInt64(regionEnd) * unit, count: end - UInt64(regionEnd) * unit)
        for (index, block) in patched {
            try out.seek(toOffset: UInt64(index) * unit)
            try out.write(contentsOf: Data(block))
        }
        try out.synchronize()
        try out.close()

        // Check the new image: the files are in the wanted order, side by side, and the UDF side agrees.
        let check = try FileHandle(forReadingFrom: temp)
        defer { try? check.close() }
        let after = try listing(check)
        guard after.map(\.name) == wanted, after.map(\.lba) == wanted.map({ newLBA[$0]! }), after.map(\.size) == wanted.map({ name in entries.first { $0.name == name }!.size }) else {
            throw Problem.unexpected("the new image does not list the files as planned")
        }
        if let (partition, fileEntries) = try udf(check, before: regionStart) {
            for name in wanted {
                let size = entries.first { $0.name == name }!.size
                let first = newLBA[name]!
                guard fileEntries.contains(where: { $0.extents.first.map { partition + $0.position == first } ?? false }) else {
                    throw Problem.unexpected("UDF does not agree for \(name) (\(size) bytes)")
                }
            }
        }
        return true
    }
}
