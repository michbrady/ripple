import CryptoKit
import Foundation

/// The table of contents of an audio disc: where each track starts, in sectors.
/// One sector holds 1/75 second of sound.
public struct DiscTOC: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var number: Int
        /// First sector. The first track usually starts at 0.
        public var lba: Int
        public var isAudio: Bool

        public init(number: Int, lba: Int, isAudio: Bool = true) {
            self.number = number
            self.lba = lba
            self.isAudio = isAudio
        }
    }

    public static let sectorsPerSecond = 75
    /// Gap between an audio session and a data session (CD-Extra): lead-out, lead-in, and pre-gap.
    static let dataSessionGap = 11_400

    public let entries: [Entry]
    /// First sector after the last track.
    public let leadOut: Int

    public init(entries: [Entry], leadOut: Int) {
        self.entries = entries
        self.leadOut = leadOut
    }

    /// Parses the formatted table of contents a drive returns for READ TOC with
    /// LBA addresses: a 4-byte header, then 8-byte descriptors ending with the
    /// lead-out (track 0xAA). Returns nil when the data is cut short or has no lead-out.
    public init?(parsing data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        let end = min(bytes.count, length + 2)
        var entries: [Entry] = []
        var leadOut: Int?
        var index = 4
        while index + 8 <= end {
            let control = bytes[index + 1] & 0x0F
            let track = Int(bytes[index + 2])
            let lba = Int(bytes[index + 4]) << 24 | Int(bytes[index + 5]) << 16
                | Int(bytes[index + 6]) << 8 | Int(bytes[index + 7])
            if track == 0xAA {
                leadOut = lba
            } else {
                entries.append(Entry(number: track, lba: lba, isAudio: control & 0x04 == 0))
            }
            index += 8
        }
        guard let leadOut, !entries.isEmpty else { return nil }
        self.init(entries: entries, leadOut: leadOut)
    }

    public var trackCount: Int { entries.count }
    public var audioTracks: [Entry] { entries.filter(\.isAudio) }

    /// The sectors that hold track `index` (0-based). An audio track that precedes
    /// a data session ends before the session gap.
    public func sectors(ofTrack index: Int) -> Range<Int> {
        let start = entries[index].lba
        let next = index + 1 < entries.count ? entries[index + 1] : nil
        var end = next?.lba ?? leadOut
        if let next, !next.isAudio { end -= Self.dataSessionGap }
        return start..<max(start, end)
    }

    public func seconds(ofTrack index: Int) -> Double {
        Double(sectors(ofTrack: index).count) / Double(Self.sectorsPerSecond)
    }

    /// The track layout MusicBrainz uses: audio tracks only, offsets plus 150 for the
    /// lead-in, and the lead-out moved back before a data session (CD-Extra).
    /// https://musicbrainz.org/doc/Disc_ID_Calculation
    var musicBrainzLayout: (first: Int, last: Int, leadOut: Int, offsets: [Int: Int])? {
        let audio = audioTracks
        guard let first = audio.first, let last = audio.last else { return nil }
        var end = leadOut
        if let firstData = entries.first(where: { !$0.isAudio && $0.number > last.number }) {
            end = firstData.lba - Self.dataSessionGap
        }
        let offsets = Dictionary(uniqueKeysWithValues: audio.map { ($0.number, $0.lba + 150) })
        return (first.number, last.number, end + 150, offsets)
    }

    /// The MusicBrainz disc ID: SHA-1 of the layout, in base64 with `+/=` swapped for `._-`.
    public var discID: String {
        guard let layout = musicBrainzLayout else { return "" }
        var text = String(format: "%02X%02X%08X", layout.first, layout.last, layout.leadOut)
        for number in 1...99 {
            text += String(format: "%08X", layout.offsets[number] ?? 0)
        }
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    /// The `toc` value for a MusicBrainz lookup of a disc it does not know yet:
    /// first track, last track, lead-out, then each track's offset, joined by `+`.
    public var musicBrainzTOC: String {
        guard let layout = musicBrainzLayout else { return "" }
        let offsets = (layout.first...layout.last).compactMap { layout.offsets[$0] }
        return ([layout.first, layout.last, layout.leadOut] + offsets).map(String.init).joined(separator: "+")
    }
}
