import Foundation

/// Writes an ID3v2.4 tag: the title, artist, and cover that Music and other players read from an MP3.
/// https://id3.org/id3v2.4.0-structure and id3v2.4.0-frames
public enum ID3Tag {
    public static func make(_ tags: TrackTags) -> Data {
        var frames = Data()
        func text(_ id: String, _ value: String) {
            guard !value.isEmpty else { return }
            frames.append(frame(id, Data([0x03]) + Data(value.utf8))) // 3 = UTF-8
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TALB", tags.album)
        text("TPE2", tags.albumArtist)
        if tags.trackNumber > 0 {
            text("TRCK", tags.trackCount > 0 ? "\(tags.trackNumber)/\(tags.trackCount)" : "\(tags.trackNumber)")
        }
        if tags.discCount > 1 { text("TPOS", "\(tags.discNumber)/\(tags.discCount)") }
        text("TDRC", tags.year)
        if tags.isCompilation { text("TCMP", "1") }
        if let cover = tags.cover, let mime = tags.coverMIMEType {
            // text encoding 0 (ISO-8859-1), MIME type, picture type 3 (front cover), empty description.
            var body = Data([0x00])
            body.append(Data(mime.utf8))
            body.append(contentsOf: [0x00, 0x03, 0x00])
            body.append(cover)
            frames.append(frame("APIC", body))
        }
        guard !frames.isEmpty else { return Data() }

        var header = Data("ID3".utf8)
        header.append(contentsOf: [0x04, 0x00, 0x00]) // version 2.4.0, no flags
        header.append(contentsOf: syncsafe(frames.count))
        return header + frames
    }

    /// A frame: four-letter id, a syncsafe size, two flag bytes, then the body.
    static func frame(_ id: String, _ body: Data) -> Data {
        var data = Data(id.utf8)
        data.append(contentsOf: syncsafe(body.count))
        data.append(contentsOf: [0x00, 0x00])
        return data + body
    }

    /// Four bytes holding 7 bits each, so no byte looks like an MPEG sync mark.
    static func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }
}
