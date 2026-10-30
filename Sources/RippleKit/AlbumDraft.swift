import Foundation

/// One track in the window: what the user sees, edits, and ticks.
public struct TrackRow: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waiting
        case ripping(Double)
        case done
        /// Saved, but some of the track could not be read cleanly.
        case needsAttention(unreadable: Int, suspect: Int)
    }

    /// The index in the disc's table of contents.
    public var id: Int
    public var number: Int
    public fileprivate(set) var title: String
    public fileprivate(set) var artist: String
    public var seconds: Double
    public var include = true
    public var status: Status = .waiting
    /// A title or artist the user typed stays when another match is chosen.
    fileprivate var titleEdited = false
    fileprivate var artistEdited = false

    public init(id: Int, number: Int, title: String, artist: String = "", seconds: Double) {
        self.id = id
        self.number = number
        self.title = title
        self.artist = artist
        self.seconds = seconds
    }
}

/// The album as the user sees it: what a lookup found, what they typed, and which
/// of the two wins. Plain values, so the rules are tested without the app.
public struct AlbumDraft: Equatable, Sendable {
    /// Empty until a lookup or the user fills them in. File names then use "Unknown Album" and "Unknown Artist".
    public private(set) var title = ""
    public private(set) var artist = ""
    public private(set) var year = ""
    public private(set) var discNumber = 1
    public private(set) var discCount = 1
    public private(set) var selectedMatchID: String?
    public var tracks: [TrackRow] = []

    private var titleEdited = false
    private var artistEdited = false

    public init() {}

    public var isCompilation: Bool { artist == "Various Artists" }

    public mutating func setTitle(_ text: String) {
        title = text
        titleEdited = true
    }

    public mutating func setArtist(_ text: String) {
        artist = text
        artistEdited = true
    }

    public mutating func setTrackTitle(_ text: String, id: Int) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].title = text
        tracks[index].titleEdited = true
    }

    public mutating func setTrackArtist(_ text: String, id: Int) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].artist = text
        tracks[index].artistEdited = true
    }

    /// Fills album, artist, year, disc N of M, and track titles from a match.
    /// Anything the user typed stays.
    public mutating func apply(_ match: AlbumMatch) {
        selectedMatchID = match.id
        if !titleEdited { title = match.title }
        if !artistEdited { artist = match.artist }
        year = match.year
        discNumber = match.discNumber
        discCount = match.discCount
        for index in tracks.indices {
            guard let track = match.tracks.first(where: { $0.number == tracks[index].number }) else { continue }
            if !tracks[index].titleEdited { tracks[index].title = track.title }
            if !tracks[index].artistEdited { tracks[index].artist = track.artist }
        }
    }

    /// Puts every title and artist back to "Track NN" and nothing, keeping the rows (for a disc with no match).
    public mutating func clearDetails() {
        self = AlbumDraft(tracks: tracks.map {
            TrackRow(id: $0.id, number: $0.number, title: String(format: "Track %02d", $0.number), seconds: $0.seconds)
        })
    }

    private init(tracks: [TrackRow]) { self.tracks = tracks }
}
