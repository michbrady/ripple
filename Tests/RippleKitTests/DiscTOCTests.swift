import Foundation
import Testing
@testable import RippleKit

/// The two example tables of contents are from https://musicbrainz.org/doc/Disc_ID_Calculation.
/// The expected IDs come from an independent Python implementation of the algorithm on that page,
/// not from a published value, so they check the code against the spec, not against MusicBrainz itself.
@Suite struct DiscTOCTests {
    static let sixTrackOffsets = [0, 15213, 32164, 46442, 63264, 80339]

    /// Builds READ TOC bytes: header, one descriptor per track, then the lead-out.
    static func rawTOC(offsets: [Int], leadOut: Int, control: [UInt8]? = nil) -> Data {
        var rows: [(UInt8, UInt8, Int)] = offsets.enumerated().map { ($0.offset < (control?.count ?? 0) ? control![$0.offset] : 0x00, UInt8($0.offset + 1), $0.element) }
        rows.append((0x00, 0xAA, leadOut))
        let length = 2 + rows.count * 8
        var bytes: [UInt8] = [UInt8(length >> 8), UInt8(length & 0xFF), 1, UInt8(offsets.count)]
        for (control, track, lba) in rows {
            bytes += [0, 0x10 | control, track, 0, UInt8(lba >> 24 & 0xFF), UInt8(lba >> 16 & 0xFF), UInt8(lba >> 8 & 0xFF), UInt8(lba & 0xFF)]
        }
        return Data(bytes)
    }

    @Test func parsesTheSixTrackDisc() throws {
        let toc = try #require(DiscTOC(parsing: Self.rawTOC(offsets: Self.sixTrackOffsets, leadOut: 95312)))
        #expect(toc.trackCount == 6)
        #expect(toc.entries.map(\.lba) == Self.sixTrackOffsets)
        #expect(toc.leadOut == 95312)
        #expect(toc.sectors(ofTrack: 0) == 0..<15213)
        #expect(toc.sectors(ofTrack: 5) == 80339..<95312)
    }

    @Test func trackLengthIsSectorsOver75() throws {
        let toc = try #require(DiscTOC(parsing: Self.rawTOC(offsets: Self.sixTrackOffsets, leadOut: 95312)))
        #expect(abs(toc.seconds(ofTrack: 0) - 15213.0 / 75.0) < 0.001)
    }

    @Test func discIDOfTheSixTrackDisc() throws {
        let toc = try #require(DiscTOC(parsing: Self.rawTOC(offsets: Self.sixTrackOffsets, leadOut: 95312)))
        #expect(toc.discID == "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")
        #expect(toc.discID.count == 28)
    }

    @Test func discIDOfACDExtraSkipsTheDataTrack() throws {
        let offsets = [0, 13959, 33436, 52927, 65631, 77742, 99024, 125824]
        let control: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x04]
        let toc = try #require(DiscTOC(parsing: Self.rawTOC(offsets: offsets, leadOut: 188333, control: control)))
        #expect(toc.trackCount == 8)
        #expect(toc.audioTracks.count == 7)
        // The last audio track ends 11400 sectors before the data session starts.
        #expect(toc.sectors(ofTrack: 6).upperBound == 125824 - 11400)
        #expect(toc.discID == "BPnh1KU.hea1C.KMYWLGZkHJr0w-")
    }

    @Test func rejectsShortOrEmptyData() {
        #expect(DiscTOC(parsing: Data([0, 2, 1, 1])) == nil)
        #expect(DiscTOC(parsing: Data()) == nil)
    }
}
