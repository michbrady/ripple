import Foundation
import Testing
@testable import RippleKit

/// tsMuxeR's own files for a two-video disc (made by tsMuxeR 2.7.0), the starting point `BluRayTitles` works from.
enum TsMuxerFiles {
    static let playlist = Data(base64Encoded: "TVBMUzAyMDAAAAA6AAAAlgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4AAQAAAAAAAAAAAABAAAAAAFgAAAABAAAAUDAwMDAwTTJUUwABAAGb/MAB7mGZAAAAAAAAAAAAAAAAAC4AAAEBAAAAAAAAAAAAAAkBEBEAAAAAAAAFG1EAAAAJAREAAAAAAAAABYExAAAAAAAAHgACAAEAAAGb/MD//wAAAAAAAQAAAcwNcP//AAAAAA==")!
    static let index = Data(base64Encoded: "SU5EWDAyMDAAAABOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJkAAAABAAAACAAAAAEAAAABAAAABAAAAAAABQAAAAAAAAAAAAAAA")!
    static let movieObjects = Data(base64Encoded: "TU9CSjAyMDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPYAAAAAAAOAAAAFUAAAAQAAAAoAAAAAUEAAAQAAAAAAAAAAUEAAAQAAAAAAAAAAQoIAAAAAAAAAAAAKAAIAAAAAAAAAAAAAgAAACVAAAAEAAAAKAAAAA1BAAAEAAAADAAD//0hAAwAAAAAKAAD//yIAAAAAAAAKAAAAAFAAAAEAAAAKAAAABFBAAAEAAAAEAAAAAEhAAwAAAAAKAAAAACEBAAAAAAAKAAAAACGBAAAAAAABAAAAAIAAAAVQQAABAAAAAAAAAABQQAABAAAAAgAAAAFQQAABAAAAAwAA//9QQAABAAAABAAAAAAhgQAAAAAAAAAAAAA=")!
}

@Suite struct BluRayTitlesTests {
    func be32(_ d: Data, _ at: Int) -> Int { BluRayTitles.be32(d, at) }

    @Test func eachVideoGetsAPlaylistThatPlaysOnlyItsPart() throws {
        let spec = try BluRayTitles.read(playlist: TsMuxerFiles.playlist)
        let second = try BluRayTitles.playlist(from: TsMuxerFiles.playlist, chapters: [70], from: 70, to: 120)
        let patched = try BluRayTitles.read(playlist: second)
        #expect(patched.inTime == spec.inTime + 70 * 45_000)
        #expect(patched.outTime == spec.inTime + 120 * 45_000)
        #expect(second.count == TsMuxerFiles.playlist.count - 14)   // one chapter mark fewer
        #expect(be32(second, patched.markStart + 6 + 4) == spec.inTime + 70 * 45_000)
    }

    @Test func thePlayEverythingPlaylistKeepsTheWholeStreamWithANewChapterForEachVideo() throws {
        let all = try BluRayTitles.playlist(from: TsMuxerFiles.playlist, chapters: [0, 65.5, 130], to: nil)
        let spec = try BluRayTitles.read(playlist: TsMuxerFiles.playlist), now = try BluRayTitles.read(playlist: all)
        #expect(now.inTime == spec.inTime && now.outTime == spec.outTime)
        #expect(Int(all[now.markStart + 4]) << 8 | Int(all[now.markStart + 5]) == 3)
        #expect(be32(all, now.markStart + 6 + 14 + 4) == spec.inTime + Int(65.5 * 45_000))
    }

    @Test func theIndexListsOneTitlePerPlaylistAfterTheTopMenu() throws {
        let index = try BluRayTitles.index(from: TsMuxerFiles.index, titles: 4)
        #expect(index.count == TsMuxerFiles.index.count + 3 * 12)
        let start = be32(index, 8)
        #expect(be32(index, start) == 12 + 12 + 2 + 4 * 12)
        #expect(Int(index[start + 4 + 6]) << 8 | Int(index[start + 4 + 7]) == 5)        // first playback: object 5
        #expect(Int(index[start + 16 + 6]) << 8 | Int(index[start + 16 + 7]) == 4)      // top menu: object 4
        #expect(Int(index[start + 28]) << 8 | Int(index[start + 29]) == 4)              // four titles
        for title in 0..<4 { #expect(Int(index[start + 30 + 12 * title + 7]) == title) }
    }

    @Test func eachTitleRunsItsOwnPlaylist() throws {
        let objects = try BluRayTitles.movieObjects(from: TsMuxerFiles.movieObjects, titles: 3)
        #expect(Int(objects[0x30]) << 8 | Int(objects[0x31]) == 5)   // three titles, the top menu, the first-playback object
        #expect(be32(objects, 0x28) == objects.count - 0x2c)
        // Each title object is 4 + 5 commands of 12 bytes; the playlist number is the first operand of the fourth command.
        let size = 4 + 5 * 12
        for title in 0..<3 { #expect(be32(objects, 0x32 + size * title + 4 + 3 * 12 + 4) == title) }
    }

    @Test func aFileThatIsNotTsMuxersIsRefusedRatherThanGuessed() {
        #expect(throws: BluRayTitles.Problem.self) { try BluRayTitles.playlist(from: Data(repeating: 0, count: 200), chapters: [0]) }
        #expect(throws: BluRayTitles.Problem.self) { try BluRayTitles.index(from: Data(repeating: 0, count: 200), titles: 2) }
        #expect(throws: BluRayTitles.Problem.self) { try BluRayTitles.movieObjects(from: Data(repeating: 0, count: 300), titles: 2) }
    }
}
