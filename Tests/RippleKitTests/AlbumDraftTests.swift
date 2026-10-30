import Testing
@testable import RippleKit

@Suite struct AlbumDraftTests {
    static func draft(tracks: Int = 3) -> AlbumDraft {
        var draft = AlbumDraft()
        draft.tracks = (1...tracks).map { TrackRow(id: $0 - 1, number: $0, title: String(format: "Track %02d", $0), seconds: 180) }
        return draft
    }

    static func match(_ id: String, title: String, artist: String = "A", discCount: Int = 1, discNumber: Int = 1,
                      suffix: String = "") -> AlbumMatch {
        AlbumMatch(id: id, title: title, artist: artist, year: "2020", discCount: discCount, discNumber: discNumber,
                   tracks: (1...3).map { .init(number: $0, title: "Song \($0)\(suffix)", artist: artist) })
    }

    @Test func aMatchFillsEverything() {
        var draft = Self.draft()
        draft.apply(Self.match("m1", title: "Album", discCount: 2, discNumber: 2))
        #expect(draft.title == "Album")
        #expect(draft.artist == "A")
        #expect(draft.year == "2020")
        #expect(draft.discNumber == 2 && draft.discCount == 2)
        #expect(draft.tracks.map(\.title) == ["Song 1", "Song 2", "Song 3"])
        #expect(draft.selectedMatchID == "m1")
    }

    @Test func anotherMatchReplacesWhatTheUserDidNotType() {
        var draft = Self.draft()
        draft.apply(Self.match("m1", title: "One"))
        draft.apply(Self.match("m2", title: "Two", suffix: " (Live)"))
        #expect(draft.title == "Two")
        #expect(draft.tracks[0].title == "Song 1 (Live)")
    }

    @Test func anEditedTrackTitleSurvivesAnotherMatch() {
        var draft = Self.draft()
        draft.apply(Self.match("m1", title: "One"))
        draft.setTrackTitle("Mine", id: 1)
        draft.apply(Self.match("m2", title: "Two", suffix: " (Live)"))
        #expect(draft.tracks[1].title == "Mine")
        #expect(draft.tracks[0].title == "Song 1 (Live)")
    }

    @Test func anEditedTrackArtistSurvivesAnotherMatch() {
        var draft = Self.draft()
        draft.apply(Self.match("m1", title: "One"))
        draft.setTrackArtist("Guest", id: 0)
        draft.apply(Self.match("m2", title: "Two", artist: "B"))
        #expect(draft.tracks[0].artist == "Guest")
        #expect(draft.tracks[1].artist == "B")
    }

    @Test func anEditedAlbumTitleAndArtistSurviveAnotherMatch() {
        var draft = Self.draft()
        draft.apply(Self.match("m1", title: "One"))
        draft.setTitle("My Album")
        draft.setArtist("Me")
        draft.apply(Self.match("m2", title: "Two", artist: "B"))
        #expect(draft.title == "My Album")
        #expect(draft.artist == "Me")
        #expect(draft.year == "2020")
    }

    @Test func editsBeforeAnyMatchStillWin() {
        var draft = Self.draft()
        draft.setTitle("Typed")
        draft.apply(Self.match("m1", title: "Found"))
        #expect(draft.title == "Typed")
    }

    @Test func unknownTrackIdsAreIgnored() {
        var draft = Self.draft()
        draft.setTrackTitle("x", id: 99)
        #expect(draft.tracks.map(\.title) == ["Track 01", "Track 02", "Track 03"])
    }

    @Test func variousArtistsMakesACompilation() {
        var draft = Self.draft()
        #expect(!draft.isCompilation)
        draft.setArtist("Various Artists")
        #expect(draft.isCompilation)
    }

    @Test func clearDetailsKeepsRowsAndForgetsTheRest() {
        var draft = Self.draft()
        draft.apply(Self.match("m1", title: "One"))
        draft.setTrackTitle("Mine", id: 0)
        draft.tracks[1].include = false
        draft.clearDetails()
        #expect(draft.title.isEmpty && draft.artist.isEmpty && draft.selectedMatchID == nil)
        #expect(draft.tracks.map(\.title) == ["Track 01", "Track 02", "Track 03"])
        draft.apply(Self.match("m2", title: "Two"))
        #expect(draft.tracks[0].title == "Song 1", "edit flags are cleared too")
    }
}
