import Foundation
import Testing
@testable import RippleKit

@Suite struct FileNamerTests {
    @Test func replacesSlashAndColon() {
        #expect(FileNamer.clean("AC/DC: Back in Black") == "AC-DC- Back in Black")
    }

    @Test func dropsControlCharactersAndEdgeDots() {
        #expect(FileNamer.clean("  ..Hidden\tSong\n ") == "Hidden Song")
        #expect(FileNamer.clean("a\u{0}b") == "ab")
    }

    @Test func normalizesToNFC() {
        let decomposed = "Cafe\u{0301}"
        let cleaned = FileNamer.clean(decomposed)
        #expect(cleaned == "Caf\u{00E9}")
        #expect(cleaned.unicodeScalars.count == 4)
    }

    @Test func usesFallbackWhenNothingIsLeft() {
        #expect(FileNamer.clean("...") == "Untitled")
        #expect(FileNamer.clean("", fallback: "Unknown Album") == "Unknown Album")
    }

    @Test func shortensWithoutSplittingACharacter() {
        let long = String(repeating: "é", count: 300)
        let name = FileNamer.trackFileName(number: 1, title: long, fileExtension: "mp3")
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".mp3"))
        #expect(name.hasPrefix("01 - é"))
        #expect(String(name.dropFirst(5).dropLast(4)).allSatisfy { $0 == "é" })
    }

    @Test func fileNameHasNumberAndTitle() {
        #expect(FileNamer.trackFileName(number: 3, title: "Song", fileExtension: "mp3") == "03 - Song.mp3")
        #expect(FileNamer.trackFileName(number: 3, title: "Song", fileExtension: "mp3", trackCount: 120) == "003 - Song.mp3")
        #expect(FileNamer.trackFileName(number: 4, title: "", fileExtension: "mp3") == "04 - Track 4.mp3")
    }

    @Test func sameTitleGetsDistinctNames() {
        var taken: Set<String> = []
        var names: [String] = []
        for _ in 0..<3 {
            let name = FileNamer.unique("01 - Intro.mp3", taken: taken)
            taken.insert(name)
            names.append(name)
        }
        #expect(names == ["01 - Intro.mp3", "01 - Intro (2).mp3", "01 - Intro (3).mp3"])
    }
}
