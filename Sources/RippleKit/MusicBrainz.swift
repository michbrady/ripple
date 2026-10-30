import Foundation

/// An album the lookup found for a disc.
public struct AlbumMatch: Equatable, Sendable, Identifiable {
    public struct Track: Equatable, Sendable {
        public var number: Int
        public var title: String
        public var artist: String

        public init(number: Int, title: String, artist: String) {
            self.number = number
            self.title = title
            self.artist = artist
        }
    }

    /// The MusicBrainz release id.
    public var id: String
    public var title: String
    public var artist: String
    public var year: String
    public var country: String
    public var format: String
    /// Discs in the release, and which one this disc is (1-based).
    public var discCount: Int
    public var discNumber: Int
    public var tracks: [Track]
    /// True when MusicBrainz lists this exact disc ID on the release, false for a fuzzy match.
    public var isExactDiscMatch: Bool

    public init(id: String, title: String, artist: String, year: String = "", country: String = "",
                format: String = "CD", discCount: Int = 1, discNumber: Int = 1,
                tracks: [Track] = [], isExactDiscMatch: Bool = true) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.country = country
        self.format = format
        self.discCount = discCount
        self.discNumber = discNumber
        self.tracks = tracks
        self.isExactDiscMatch = isExactDiscMatch
    }

    public var isCompilation: Bool { artist == "Various Artists" }

    /// The front cover from the Cover Art Archive. It answers 404 when there is none.
    public var coverURL: URL { URL(string: "https://coverartarchive.org/release/\(id)/front-500")! }

    /// "2004 · SK · CD · 6 tracks"
    public var detail: String {
        [year, country, format, "\(tracks.count) tracks"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum MusicBrainz {
    public static func lookupURL(for toc: DiscTOC) -> URL {
        var parts = URLComponents(string: "https://musicbrainz.org/ws/2/discid/\(toc.discID)")!
        parts.queryItems = [
            .init(name: "fmt", value: "json"),
            .init(name: "inc", value: "artist-credits recordings release-groups"),
            .init(name: "toc", value: toc.musicBrainzTOC),
            .init(name: "cdstubs", value: "no"),
        ]
        // The service wants `+` between inc values, and URLComponents writes a space as %20.
        let text = parts.url!.absoluteString.replacingOccurrences(of: "artist-credits%20recordings%20release-groups",
                                                                   with: "artist-credits+recordings+release-groups")
        return URL(string: text)!
    }

    /// Reads a disc ID lookup response into matches, best first.
    public static func parse(_ data: Data, discID: String, trackCount: Int) throws -> [AlbumMatch] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let matches = (response.releases ?? []).compactMap { $0.match(discID: discID, trackCount: trackCount) }
        return matches.sorted { rank($0) < rank($1) }
    }

    /// Exact disc ID first, then CDs, then the earliest year.
    private static func rank(_ match: AlbumMatch) -> String {
        [match.isExactDiscMatch ? "0" : "1", match.format == "CD" ? "0" : "1",
         match.year.isEmpty ? "9999" : match.year, match.title].joined(separator: "|")
    }

    // MARK: Response shape

    struct Response: Decodable { var releases: [Release]? }

    struct Credit: Decodable {
        var name: String
        var joinphrase: String?
    }

    struct Release: Decodable {
        var id: String
        var title: String
        var date: String?
        var country: String?
        var artistCredit: [Credit]?
        var media: [Medium]?

        enum CodingKeys: String, CodingKey {
            case id, title, date, country, media
            case artistCredit = "artist-credit"
        }

        func match(discID: String, trackCount: Int) -> AlbumMatch? {
            let media = media ?? []
            let exact = media.firstIndex { $0.discs?.contains { $0.id == discID } == true }
            guard let index = exact ?? media.firstIndex(where: { $0.tracks?.count == trackCount }) else { return nil }
            let medium = media[index]
            let tracks = (medium.tracks ?? []).enumerated().map { offset, track in
                AlbumMatch.Track(number: track.position ?? offset + 1, title: track.title,
                                 artist: Self.name(track.artistCredit ?? track.recording?.artistCredit))
            }
            return AlbumMatch(id: id, title: title, artist: Self.name(artistCredit),
                              year: String((date ?? "").prefix(4)), country: country ?? "",
                              format: medium.format ?? "CD", discCount: max(1, media.count),
                              discNumber: medium.position ?? index + 1, tracks: tracks,
                              isExactDiscMatch: exact != nil)
        }

        static func name(_ credits: [Credit]?) -> String {
            (credits ?? []).map { $0.name + ($0.joinphrase ?? "") }.joined()
        }
    }

    struct Medium: Decodable {
        var position: Int?
        var format: String?
        var discs: [Disc]?
        var tracks: [Track]?
    }

    struct Disc: Decodable { var id: String }

    struct Track: Decodable {
        var position: Int?
        var title: String
        var artistCredit: [Credit]?
        var recording: Recording?

        enum CodingKeys: String, CodingKey {
            case position, title, recording
            case artistCredit = "artist-credit"
        }
    }

    struct Recording: Decodable {
        var artistCredit: [Credit]?
        enum CodingKeys: String, CodingKey { case artistCredit = "artist-credit" }
    }
}

/// Looks discs up on MusicBrainz, at most one request per `minInterval`
/// (the service answers 503 above one per second), retrying a 503 after a pause.
public actor MusicBrainzClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (data: Data, status: Int)

    public enum LookupError: Error, Equatable { case badStatus(Int) }

    private let userAgent: String
    private let minInterval: Duration
    private let retryPause: Duration
    private let transport: Transport
    private var lastRequest: ContinuousClock.Instant?

    /// `userAgent` should name the app and a way to reach its author, as MusicBrainz asks.
    public init(userAgent: String, minInterval: Duration = .seconds(1), retryPause: Duration = .seconds(2),
                transport: @escaping Transport = MusicBrainzClient.liveTransport) {
        self.userAgent = userAgent
        self.minInterval = minInterval
        self.retryPause = retryPause
        self.transport = transport
    }

    public static let liveTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func lookup(toc: DiscTOC) async throws -> [AlbumMatch] {
        var request = URLRequest(url: MusicBrainz.lookupURL(for: toc))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        for attempt in 0..<3 {
            try await throttle()
            let (data, status) = try await transport(request)
            switch status {
            case 200:
                return try MusicBrainz.parse(data, discID: toc.discID, trackCount: toc.audioTracks.count)
            case 404:
                return []
            case 503 where attempt < 2:
                try await Task.sleep(for: retryPause * (attempt + 1))
            default:
                throw LookupError.badStatus(status)
            }
        }
        throw LookupError.badStatus(503)
    }

    private func throttle() async throws {
        if let last = lastRequest {
            let wait = minInterval - (ContinuousClock.now - last)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastRequest = .now
    }
}

public enum CoverArt {
    /// Fetches a URL, returning the bytes and HTTP status, or nil when the network fails.
    public typealias Fetch = @Sendable (URL) async -> (data: Data, status: Int)?

    public static let liveFetch: Fetch = { url in
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        return (data, status)
    }

    /// The front cover image bytes. Tries the Cover Art Archive first, then the iTunes Search API
    /// for albums the archive has no picture for. Returns nil when neither has one.
    public static func fetch(for match: AlbumMatch, using fetch: Fetch = liveFetch) async -> Data? {
        if let result = await fetch(match.coverURL), result.status == 200, !result.data.isEmpty {
            return result.data
        }
        guard let url = iTunesSearchURL(for: match),
              let search = await fetch(url), search.status == 200,
              let artwork = iTunesArtworkURL(in: search.data, for: match),
              let image = await fetch(artwork), image.status == 200, !image.data.isEmpty else { return nil }
        return image.data
    }

    static func iTunesSearchURL(for match: AlbumMatch) -> URL? {
        var parts = URLComponents(string: "https://itunes.apple.com/search")
        let term = match.isCompilation ? match.title : "\(match.artist) \(match.title)"
        parts?.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "album"),
                             .init(name: "limit", value: "5")]
        return parts?.url
    }

    /// The artwork of the first result whose album name matches the title (ignoring case,
    /// punctuation, and extras like "(Deluxe Edition)"), enlarged to 600 pixels.
    static func iTunesArtworkURL(in data: Data, for match: AlbumMatch) -> URL? {
        struct Response: Decodable {
            struct Result: Decodable { var collectionName: String?; var artworkUrl100: String? }
            var results: [Result]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let wanted = normalized(match.title)
        guard !wanted.isEmpty else { return nil }
        for result in response.results {
            guard let name = result.collectionName, let art = result.artworkUrl100 else { continue }
            let found = normalized(name)
            if found == wanted || found.hasPrefix(wanted) || wanted.hasPrefix(found), !found.isEmpty {
                return URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
            }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        let base = text.lowercased().split(separator: "(").first.map(String.init) ?? text.lowercased()
        return String(base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
