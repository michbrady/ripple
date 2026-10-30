import Foundation

/// What gets written into one finished file.
public struct TrackTags: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var year: String
    public var trackNumber: Int
    public var trackCount: Int
    public var discNumber: Int
    public var discCount: Int
    public var isCompilation: Bool
    /// JPEG or PNG bytes.
    public var cover: Data?

    public init(title: String, artist: String = "", album: String = "", albumArtist: String = "", year: String = "",
                trackNumber: Int = 0, trackCount: Int = 0, discNumber: Int = 1, discCount: Int = 1,
                isCompilation: Bool = false, cover: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.isCompilation = isCompilation
        self.cover = cover
    }

    /// "image/jpeg" or "image/png" from the first bytes, or nil for anything else.
    public var coverMIMEType: String? {
        guard let cover, cover.count > 8 else { return nil }
        let head = [UInt8](cover.prefix(4))
        if head.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if head == [0x89, 0x50, 0x4E, 0x47] { return "image/png" }
        return nil
    }
}
