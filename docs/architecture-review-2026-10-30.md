# Architecture review, 2026-10-30

Check-in at the end of M2, before M3 (tags, MP3 quality, M4A). Survey of about 3,000 lines: no file near the size limits, no duplicate private types, no fix-log entries yet. The code is in good shape. The one real signal is that `AppModel` (409 lines) owns too many jobs, and M3 is about to add more.

## Album details as a plain type, not model state  [Strong]

Files: Sources/Ripple/Models.swift (409 lines), Sources/Ripple/SelfTest.swift
Signal: pure logic inside a `@MainActor` store; before a big feature (M3 writes tags from this data).
Problem: The rules for merging a lookup match with what the user typed (which fields were edited, which titles to replace, disc N of M) live in `AppModel.apply`, next to I/O and UI state. They can be tested only through the whole app (the self-test), and M3's tagger needs the same data (title, artist, year, disc, tracks) and would have to reach into the model for it.
Proposal: A plain `AlbumDraft` in RippleKit, with `TrackRow` moved beside it.

```swift
public struct AlbumDraft: Equatable, Sendable {
    public var title = "", artist = "", year = ""
    public var discNumber = 1, discCount = 1
    public var tracks: [TrackRow] = []
    public private(set) var selectedMatchID: String?
    public var isCompilation: Bool { artist == "Various Artists" }
    public mutating func setTitle(_ text: String)
    public mutating func setArtist(_ text: String)
    public mutating func setTrackTitle(_ text: String, id: Int)
    public mutating func setTrackArtist(_ text: String, id: Int)
    /// Fills fields from a match; anything the user typed stays.
    public mutating func apply(_ match: AlbumMatch)
}
```

`AppModel` holds one `album: AlbumDraft` and forwards `rows`, `albumTitle`, and the rest, so views do not change.
Benefits: Locality: the merge rules sit in one file with unit tests. Leverage: M3's tagger and the burn feature take an `AlbumDraft` and need no model. About 60 lines leave `AppModel`. Three self-test checks about edit rules become fast unit tests.
Proof of same behavior: all 38 unit tests and 32 self-test checks pass before and after; the snapshot layout files for tracks, unmatched, and picker are unchanged.
Plan: 1) add `AlbumDraft` and `TrackRow` to RippleKit with tests (compiles first). 2) Move `AppModel` onto it and delete the old fields. 3) Trim the self-test checks the unit tests now cover.

## Snapshot seeding out of AppModel  [Worth exploring]

Files: Sources/Ripple/Models.swift (`showSnapshot`, 40 lines)
Signal: test hooks in the app type.
Problem: Snapshot state setup sits inside the model that ships to users.
Proposal: Move `showSnapshot` into an `extension AppModel` in `Snapshot.swift`. No new interface.
Benefits: The model file shrinks by 40 lines and snapshot code lives with snapshot code.
Proof of same behavior: snapshot PNGs and layout files match.
Plan: one commit, after the first card.

## A job type for ripping and burning  [Speculative]

Files: Sources/Ripple/Models.swift (`rip`, `cancel`, `finishRip`, `stopRipping`)
Signal: none yet; M5 adds a second long job (burning) with the same start, progress, cancel, and quit-prompt shape.
Problem: None today. Two jobs would copy the cancel and quit-prompt code.
Proposal: Decide when burning starts. Extract then, with two real callers.
Benefits: Avoids a seam with one adapter.
Proof of same behavior: n/a.
Plan: revisit at the start of M5.

## Top recommendation

Do the first card: `AlbumDraft`. It is the only one with a real signal, and M3 depends on it.

## Considered, not recommended

- **`AudioDisc` and `AlbumLookup` protocols.** Each has two adapters (a real one and a fixture), so both seams are real and earn their place.
- **Splitting `ContentView` (357 lines).** Under the limit, and each type in it is a separate view already.
- **A wrapper around `DiscMonitor`.** It is a thin shell over DiskArbitration, but there is only one caller and nothing to swap.
- **Moving `LiveLookup` into RippleKit.** It holds the app's contact string for MusicBrainz; keeping it in the app target keeps that decision in one visible place.
