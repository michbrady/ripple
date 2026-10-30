import Foundation
import Testing
@testable import RippleKit

@Suite struct MusicBrainzTests {
    /// The six-track disc from https://musicbrainz.org/doc/Disc_ID_Calculation.
    static var toc: DiscTOC {
        let offsets = [0, 15213, 32164, 46442, 63264, 80339]
        return DiscTOC(entries: offsets.enumerated().map { .init(number: $0.offset + 1, lba: $0.element) }, leadOut: 95312)
    }

    static func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "musicbrainz-discid", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func discIDMatchesMusicBrainzsOwnRecord() throws {
        // The saved response is MusicBrainz's answer for this disc: it lists the same ID and offsets.
        let json = try #require(try JSONSerialization.jsonObject(with: Self.fixture()) as? [String: Any])
        #expect(json["id"] as? String == Self.toc.discID)
        #expect(json["offsets"] as? [Int] == [150, 15363, 32314, 46592, 63414, 80489])
    }

    @Test func buildsTheTOCQuery() {
        #expect(Self.toc.musicBrainzTOC == "1+6+95462+150+15363+32314+46592+63414+80489")
        let url = MusicBrainz.lookupURL(for: Self.toc).absoluteString
        #expect(url.contains("/ws/2/discid/49HHV7Eb8UKF3aQiNmu1GR8vKTY-?"))
        #expect(url.contains("inc=artist-credits+recordings+release-groups"))
        #expect(url.contains("toc=1+6+95462+150"))
        #expect(url.contains("fmt=json"))
    }

    @Test func parsesTheRealResponse() throws {
        let matches = try MusicBrainz.parse(Self.fixture(), discID: Self.toc.discID, trackCount: 6)
        let match = try #require(matches.first)
        #expect(matches.count == 1)
        #expect(match.title == "Ettella Diamant")
        #expect(match.artist == "Ettella Diamant")
        #expect(match.year == "2004")
        #expect(match.country == "SK")
        #expect(match.format == "CD")
        #expect(match.tracks.count == 6)
        #expect(match.tracks[0].title == "Rysperdal Gstp")
        #expect(match.tracks[0].artist == "Ettella Diamant")
        #expect(match.isExactDiscMatch)
        #expect(match.coverURL.absoluteString == "https://coverartarchive.org/release/d3dc4be9-9749-4959-99e5-133d0cb467fe/front-500")
    }

    @Test func ranksExactMatchFirstThenCDThenEarliest() throws {
        let json = """
        {"releases":[
          {"id":"b","title":"Fuzzy","date":"1990","artist-credit":[{"name":"X"}],"media":[{"position":1,"format":"CD","tracks":[{"title":"t"}]}]},
          {"id":"c","title":"Exact Vinyl","date":"1980","artist-credit":[{"name":"X"}],"media":[{"position":1,"format":"Vinyl","discs":[{"id":"ID"}],"tracks":[{"title":"t"}]}]},
          {"id":"a","title":"Exact CD Late","date":"2010","artist-credit":[{"name":"X"}],"media":[{"position":1,"format":"CD","discs":[{"id":"ID"}],"tracks":[{"title":"t"}]}]},
          {"id":"d","title":"Exact CD Early","date":"2001","artist-credit":[{"name":"X"}],"media":[{"position":1,"format":"CD","discs":[{"id":"ID"}],"tracks":[{"title":"t"}]}]}
        ]}
        """
        let matches = try MusicBrainz.parse(Data(json.utf8), discID: "ID", trackCount: 1)
        #expect(matches.map(\.title) == ["Exact CD Early", "Exact CD Late", "Exact Vinyl", "Fuzzy"])
        #expect(matches.map(\.isExactDiscMatch) == [true, true, true, false])
    }

    @Test func findsTheRightDiscOfASetAndJoinsArtists() throws {
        let json = """
        {"releases":[{"id":"r","title":"Set","date":"1999-05-01","artist-credit":[{"name":"A","joinphrase":" & "},{"name":"B"}],
          "media":[{"position":1,"format":"CD","discs":[{"id":"OTHER"}],"tracks":[{"title":"one"}]},
                   {"position":2,"format":"CD","discs":[{"id":"ID"}],"tracks":[{"position":1,"title":"two","recording":{"artist-credit":[{"name":"Guest"}]}}]}]}]}
        """
        let match = try #require(try MusicBrainz.parse(Data(json.utf8), discID: "ID", trackCount: 1).first)
        #expect(match.artist == "A & B")
        #expect(match.discCount == 2)
        #expect(match.discNumber == 2)
        #expect(match.tracks.map(\.title) == ["two"])
        #expect(match.tracks[0].artist == "Guest")
        #expect(match.year == "1999")
    }

    @Test func variousArtistsIsACompilation() {
        #expect(AlbumMatch(id: "x", title: "Hits", artist: "Various Artists").isCompilation)
        #expect(!AlbumMatch(id: "x", title: "Hits", artist: "Someone").isCompilation)
    }
}

@Suite struct MusicBrainzClientTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [ContinuousClock.Instant] = []
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) -> Int {
            lock.lock(); defer { lock.unlock() }
            times.append(.now); requests.append(request)
            return times.count
        }
        var snapshot: (times: [ContinuousClock.Instant], requests: [URLRequest]) {
            lock.lock(); defer { lock.unlock() }
            return (times, requests)
        }
    }

    @Test func sendsAUserAgentAndNeverExceedsTheRate() async throws {
        let calls = Calls()
        let body = try MusicBrainzTests.fixture()
        let client = MusicBrainzClient(userAgent: "Ripple/0.1 (test)", minInterval: .milliseconds(300)) { request in
            _ = calls.add(request)
            return (body, 200)
        }
        for _ in 0..<3 { _ = try await client.lookup(toc: MusicBrainzTests.toc) }
        let (times, requests) = calls.snapshot
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "Ripple/0.1 (test)" })
        for index in 1..<times.count {
            #expect(times[index] - times[index - 1] >= .milliseconds(280), "gap \(times[index] - times[index - 1])")
        }
    }

    @Test func retriesAfterA503() async throws {
        let calls = Calls()
        let body = try MusicBrainzTests.fixture()
        let client = MusicBrainzClient(userAgent: "t", minInterval: .milliseconds(10), retryPause: .milliseconds(50)) { request in
            (calls.add(request) == 1 ? Data() : body, calls.snapshot.requests.count == 1 ? 503 : 200)
        }
        let matches = try await client.lookup(toc: MusicBrainzTests.toc)
        #expect(matches.count == 1)
        #expect(calls.snapshot.requests.count == 2)
    }

    @Test func unknownDiscGivesNoMatchesAndOtherErrorsThrow() async throws {
        let notFound = MusicBrainzClient(userAgent: "t", minInterval: .milliseconds(1)) { _ in (Data(), 404) }
        #expect(try await notFound.lookup(toc: MusicBrainzTests.toc).isEmpty)
        let broken = MusicBrainzClient(userAgent: "t", minInterval: .milliseconds(1)) { _ in (Data(), 500) }
        await #expect(throws: MusicBrainzClient.LookupError.badStatus(500)) { _ = try await broken.lookup(toc: MusicBrainzTests.toc) }
    }
}

@Suite struct CoverArtTests {
    static let match = AlbumMatch(id: "abc", title: "Sine Waves", artist: "The Tones")
    static let image = Data([0xFF, 0xD8, 0xFF, 0xE0])

    static func itunes(_ name: String) -> Data {
        Data("""
        {"resultCount":1,"results":[{"collectionName":"\(name)","artworkUrl100":"https://img.example/a/100x100bb.jpg"}]}
        """.utf8)
    }

    @Test func usesTheCoverArtArchiveFirst() async {
        let urls = MusicBrainzClientTests.Calls()
        let cover = await CoverArt.fetch(for: Self.match) { url in
            _ = urls.add(URLRequest(url: url))
            return (Self.image, 200)
        }
        #expect(cover == Self.image)
        #expect(urls.snapshot.requests.count == 1)
        #expect(urls.snapshot.requests[0].url == Self.match.coverURL)
    }

    @Test func fallsBackToITunesWhenTheArchiveHasNoCover() async {
        let urls = MusicBrainzClientTests.Calls()
        let cover = await CoverArt.fetch(for: Self.match) { url in
            _ = urls.add(URLRequest(url: url))
            switch url.host {
            case "coverartarchive.org": return (Data(), 404)
            case "itunes.apple.com": return (Self.itunes("Sine Waves (Deluxe Edition)"), 200)
            default: return (Self.image, 200)
            }
        }
        #expect(cover == Self.image)
        let seen = urls.snapshot.requests.compactMap(\.url)
        #expect(seen.last?.absoluteString == "https://img.example/a/600x600bb.jpg")
        #expect(seen[1].absoluteString.contains("term=The%20Tones%20Sine%20Waves") || seen[1].absoluteString.contains("term=The+Tones+Sine+Waves"))
    }

    @Test func ignoresAnITunesResultForADifferentAlbum() async {
        let cover = await CoverArt.fetch(for: Self.match) { url in
            switch url.host {
            case "coverartarchive.org": (Data(), 404)
            case "itunes.apple.com": (Self.itunes("Something Else Entirely"), 200)
            default: (Self.image, 200)
            }
        }
        #expect(cover == nil)
    }

    @Test func givesNilWhenTheNetworkFails() async {
        #expect(await CoverArt.fetch(for: Self.match) { _ in nil } == nil)
    }
}

/// Talks to the real services, so it runs only when asked: RIPPLE_LIVE=1 swift test --filter LiveLookup
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RIPPLE_LIVE"] == "1")) struct LiveLookup {
    @Test func findsTheExampleDiscAndItsCover() async throws {
        let client = MusicBrainzClient(userAgent: "Ripple-test/0.1 (development, no contact)")
        let matches = try await client.lookup(toc: MusicBrainzTests.toc)
        let match = try #require(matches.first)
        #expect(match.title == "Ettella Diamant")
        #expect(match.tracks.count == 6)
        #expect(match.isExactDiscMatch)
        let cover = try #require(await CoverArt.fetch(for: match))
        #expect(cover.count > 1_000)
        #expect(cover.prefix(2) == Data([0xFF, 0xD8]), "expected a JPEG")
    }
}
