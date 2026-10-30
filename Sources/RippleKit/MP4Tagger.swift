import Foundation

/// Adds iTunes-style tags (the `udta/meta/ilst` atoms) to an .m4a file.
///
/// Core Audio writes `ftyp`, `moov`, a block of `free` padding, then `mdat`. A cover picture may not fit
/// in that padding, so the file is rebuilt: a new `moov` carries the tags, the padding goes, and every
/// chunk offset in the `stco` and `co64` tables moves by however far `mdat` moved. The audio bytes are copied as they are.
enum MP4Tagger {
    enum TagError: Error { case notMP4, offsetOutOfRange }

    struct Box { var type: String; var start: Int; var size: Int; var headerSize: Int }

    static func apply(_ tags: TrackTags, to url: URL) throws {
        let original = try Data(contentsOf: url)
        let top = try parse(original, from: 0, to: original.count)
        guard let moov = top.first(where: { $0.type == "moov" }),
              let mdat = top.first(where: { $0.type == "mdat" }) else { throw TagError.notMP4 }

        // The new moov: everything the old one had except its own tags, plus ours.
        var body = Data()
        for child in try parse(original, from: moov.start + moov.headerSize, to: moov.start + moov.size) where child.type != "udta" {
            body.append(original[child.start ..< child.start + child.size])
        }
        body.append(box("udta", box("meta", Data([0, 0, 0, 0]) + handlerBox() + box("ilst", items(tags)))))
        var newMoov = box("moov", body)

        // Where mdat lands once the padding is gone and moov has its new size.
        var position = 0
        var newMdatStart = 0
        for b in top where b.type != "free" {
            if b.type == "mdat" { newMdatStart = position }
            position += b.type == "moov" ? newMoov.count : b.size
        }
        try shiftChunkOffsets(in: &newMoov, by: newMdatStart - mdat.start)

        var output = Data(capacity: position)
        for b in top where b.type != "free" {
            output.append(b.type == "moov" ? newMoov : original[b.start ..< b.start + b.size])
        }
        let temporary = url.appendingPathExtension("tagged")
        try output.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    // MARK: Reading

    static func parse(_ data: Data, from start: Int, to end: Int) throws -> [Box] {
        var boxes: [Box] = []
        var position = start
        while position + 8 <= end {
            var size = Int(readUInt32(data, position))
            let type = String(decoding: data[position + 4 ..< position + 8], as: UTF8.self)
            var headerSize = 8
            if size == 1 { // a 64-bit size follows
                guard position + 16 <= end else { throw TagError.notMP4 }
                size = Int(truncatingIfNeeded: readUInt64(data, position + 8))
                headerSize = 16
            } else if size == 0 { // runs to the end
                size = end - position
            }
            guard size >= headerSize, position + size <= end else { throw TagError.notMP4 }
            boxes.append(Box(type: type, start: position, size: size, headerSize: headerSize))
            position += size
        }
        return boxes
    }

    static func readUInt32(_ data: Data, _ at: Int) -> UInt32 {
        data[data.startIndex + at ..< data.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func readUInt64(_ data: Data, _ at: Int) -> UInt64 {
        data[data.startIndex + at ..< data.startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Adds `delta` to every entry of every `stco` and `co64` table under `moov`.
    static func shiftChunkOffsets(in moov: inout Data, by delta: Int) throws {
        guard delta != 0 else { return }
        func walk(_ start: Int, _ end: Int) throws {
            for child in try parse(moov, from: start, to: end) {
                switch child.type {
                case "trak", "mdia", "minf", "stbl":
                    try walk(child.start + child.headerSize, child.start + child.size)
                case "stco", "co64":
                    let wide = child.type == "co64"
                    let width = wide ? 8 : 4
                    let count = Int(readUInt32(moov, child.start + 12))
                    guard child.start + 16 + count * width <= child.start + child.size else { throw TagError.notMP4 }
                    for index in 0..<count {
                        let at = child.start + 16 + index * width
                        let old = wide ? Int(truncatingIfNeeded: readUInt64(moov, at)) : Int(readUInt32(moov, at))
                        let new = old + delta
                        guard new >= 0, wide || new <= Int(UInt32.max) else { throw TagError.offsetOutOfRange }
                        let bytes = wide ? be64(UInt64(new)) : be32(UInt32(new))
                        moov.replaceSubrange(at ..< at + width, with: bytes)
                    }
                default:
                    break
                }
            }
        }
        try walk(8, moov.count)
    }

    // MARK: Building

    static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func be64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8(value >> UInt64(56 - 8 * $0) & 0xFF) })
    }

    static func be16(_ value: Int) -> Data { Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }

    /// size, four-character type, payload. Types may start with © (byte 0xA9).
    static func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + fourCC(type) + payload
    }

    static func fourCC(_ type: String) -> Data {
        Data(type.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    /// The `hdlr` box that marks the metadata as iTunes-style (`mdir`, vendor `appl`).
    static func handlerBox() -> Data {
        var payload = Data([0, 0, 0, 0, 0, 0, 0, 0])      // version/flags, predefined
        payload.append(Data("mdir".utf8))
        payload.append(Data("appl".utf8))
        payload.append(Data(repeating: 0, count: 9))     // reserved, then an empty name
        return box("hdlr", payload)
    }

    /// A tag item: its box wraps one `data` box with a type code and the value.
    static func item(_ type: String, code: UInt32, _ value: Data) -> Data {
        box(type, box("data", be32(code) + be32(0) + value))
    }

    static func items(_ tags: TrackTags) -> Data {
        var out = Data()
        func text(_ type: String, _ value: String) {
            if !value.isEmpty { out.append(item(type, code: 1, Data(value.utf8))) }
        }
        text("\u{A9}nam", tags.title)
        text("\u{A9}ART", tags.artist)
        text("\u{A9}alb", tags.album)
        text("aART", tags.albumArtist)
        text("\u{A9}day", tags.year)
        if tags.trackNumber > 0 {
            out.append(item("trkn", code: 0, Data([0, 0]) + be16(tags.trackNumber) + be16(tags.trackCount) + Data([0, 0])))
        }
        if tags.discCount > 1 {
            out.append(item("disk", code: 0, Data([0, 0]) + be16(tags.discNumber) + be16(tags.discCount)))
        }
        if tags.isCompilation { out.append(item("cpil", code: 21, Data([1]))) }
        if let cover = tags.cover, let mime = tags.coverMIMEType {
            out.append(item("covr", code: mime == "image/png" ? 14 : 13, cover))
        }
        return out
    }
}
