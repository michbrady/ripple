import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RippleKit
import UniformTypeIdentifiers

/// Finds the album for a disc, and its cover.
nonisolated protocol AlbumLookup: Sendable {
    func matches(for toc: DiscTOC) async throws -> [AlbumMatch]
    func cover(for match: AlbumMatch) async -> Data?
}

/// MusicBrainz and the Cover Art Archive.
nonisolated struct LiveLookup: AlbumLookup {
    /// MusicBrainz asks every app to name itself and a way to reach its author.
    /// Add yours here (an email or a web page) before you share Ripple.
    static let contact = ""

    private let client = MusicBrainzClient(userAgent: "Ripple/0.1" + (contact.isEmpty ? "" : " ( \(contact) )"))

    func matches(for toc: DiscTOC) async throws -> [AlbumMatch] { try await client.lookup(toc: toc) }
    func cover(for match: AlbumMatch) async -> Data? { await CoverArt.fetch(for: match) }
}

/// Made-up albums for the fixture disc, self-test, and snapshots. Never touches the network.
nonisolated struct FixtureLookup: AlbumLookup {
    /// `single` finds exactly one exact match, the case that starts a rip on its own.
    enum Mode: Sendable { case found, single, none, offline }
    struct Offline: Error {}

    var mode: Mode = .found

    static let titles = ["Low A", "Rising Fifth", "High/C", "Quiet Interval", "Overtone", "Beat Frequency",
                         "Standing Wave", "Long Tone: Finale", "Decay", "Resonance", "Harmonic", "Fade Out"]

    /// Two matches: the plain release (exact), and a two-disc deluxe edition (fuzzy).
    static func albums(trackCount: Int) -> [AlbumMatch] {
        let tracks = (1...max(1, trackCount)).map { AlbumMatch.Track(number: $0, title: titles[($0 - 1) % titles.count], artist: "The Tones") }
        return [
            AlbumMatch(id: "fixture-1", title: "Sine Waves", artist: "The Tones", year: "2020", country: "US",
                       tracks: tracks),
            AlbumMatch(id: "fixture-2", title: "Sine Waves (Deluxe Edition)", artist: "The Tones", year: "2021", country: "JP",
                       discCount: 2, discNumber: 2, tracks: tracks.map { .init(number: $0.number, title: $0.title + " (Live)", artist: $0.artist) },
                       isExactDiscMatch: false),
        ]
    }

    func matches(for toc: DiscTOC) async throws -> [AlbumMatch] {
        switch mode {
        case .found: Self.albums(trackCount: toc.audioTracks.count)
        case .single: Array(Self.albums(trackCount: toc.audioTracks.count).prefix(1))
        case .none: []
        case .offline: throw Offline()
        }
    }

    func cover(for match: AlbumMatch) async -> Data? { mode == .found || mode == .single ? Self.coverPNG() : nil }

    /// A plain teal square, as PNG bytes.
    static func coverPNG() -> Data {
        let size = 192
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.05, green: 0.58, blue: 0.72, alpha: 1), CGColor(red: 0.02, green: 0.30, blue: 0.45, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: 48, y: 48, width: 96, height: 96))
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 84, y: 84, width: 24, height: 24))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
