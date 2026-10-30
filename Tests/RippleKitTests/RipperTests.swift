import AVFoundation
import Foundation
import Testing
@testable import RippleKit

@Suite struct RipperTests {
    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ripple-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func request(disc: FixtureDisc, folder: URL, titles: [String]) -> RipRequest {
        let tracks = titles.enumerated().map { RipTrack(number: $0.offset + 1, title: $0.element) }
        return RipRequest(disc: disc, tracks: tracks, albumArtist: "The Tones", album: "Sine Waves", folder: folder)
    }

    @Test func fixtureReadsExactByteCount() throws {
        let disc = FixtureDisc()
        let data = try disc.readSectors(start: 0, count: 10)
        #expect(data.count == 10 * 2352)
        #expect(throws: DiscError.outOfRange) { _ = try disc.readSectors(start: disc.toc.leadOut, count: 1) }
    }

    @Test func fixtureReadsAreFreshAndRepeatable() throws {
        let disc = FixtureDisc()
        #expect(try disc.readSectors(start: 40, count: 2) == disc.readSectors(start: 40, count: 2))
    }

    @Test func encoderMakesAnMP3WithTheRightDuration() throws {
        let disc = FixtureDisc(trackSeconds: [3])
        let encoder = try MP3Encoder(quality: .vbr(2))
        var out = Data()
        out.append(try encoder.encode(try disc.readSectors(start: 0, count: disc.toc.leadOut)))
        let (tail, tag) = try encoder.finish()
        out.append(tail)
        if !tag.isEmpty { out.replaceSubrange(0..<tag.count, with: tag) }
        let url = FileManager.default.temporaryDirectory.appending(path: "ripple-\(UUID().uuidString).mp3")
        try out.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 3.0) < 0.15, "decoded length \(seconds) s")
    }

    @Test func cbrEncodeReportsTheRequestedBitrate() throws {
        let disc = FixtureDisc(trackSeconds: [2])
        let encoder = try MP3Encoder(quality: .cbr(192))
        let data = try encoder.encode(try disc.readSectors(start: 0, count: disc.toc.leadOut)) + (try encoder.finish()).tail
        // A 2-second CBR 192 kbps file is about 48 000 bytes.
        #expect(abs(Double(data.count) - 48_000) < 3_000, "\(data.count) bytes")
    }

    @Test func ripsEveryTrackToNamedFiles() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = FixtureDisc()
        let files = try Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["Low A", "High/C", "Same"]), onEvent: { _ in })
        let names = files.map(\.lastPathComponent)
        #expect(names == ["01 - Low A.mp3", "02 - High-C.mp3", "03 - Same.mp3"])
        #expect(files.allSatisfy { $0.deletingLastPathComponent().path.hasSuffix("The Tones/Sine Waves") })
        let file = try AVAudioFile(forReading: files[1])
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3.0) < 0.15)
    }

    @Test func uncheckedTracksMakeNoFiles() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = Self.request(disc: FixtureDisc(), folder: folder, titles: ["A", "B", "C"])
        request.tracks[1].include = false
        let files = try Ripper.rip(request, onEvent: { _ in })
        #expect(files.map(\.lastPathComponent) == ["01 - A.mp3", "03 - C.mp3"])
    }

    @Test func reportsProgressForEachTrack() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Locked<[RipEvent]>([])
        _ = try Ripper.rip(Self.request(disc: FixtureDisc(trackSeconds: [1]), folder: folder, titles: ["Only"])) { event in
            events.withLock { $0.append(event) }
        }
        let seen = events.withLock { $0 }
        #expect(seen.first == .started(track: 0))
        #expect(seen.contains(.progress(track: 0, fraction: 1)))
        #expect(seen.last.map { if case .finished = $0 { true } else { false } } == true)
    }

    @Test func cancelKeepsFinishedTracksAndLeavesNoPartialFile() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = Self.request(disc: FixtureDisc(trackSeconds: [1, 20, 1]), folder: folder, titles: ["One", "Long", "Three"])
        let task = Task.detached {
            try Ripper.rip(request) { event in
                // Stop in the middle of the long second track.
                if case .progress(let track, let fraction) = event, track == 1, fraction > 0.2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let album = folder.appending(path: "The Tones/Sine Waves")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: album.path)) ?? []).sorted()
        #expect(names == ["01 - One.mp3"], "left behind: \(names)")
    }

    @Test func unreadableSectorFailsTheTrackAndRemovesItsFile() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = FixtureDisc(trackSeconds: [1, 1], badSectors: [100])
        #expect(throws: DiscError.unreadable(sector: 100)) {
            _ = try Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["Good", "Bad"]), onEvent: { _ in })
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "The Tones/Sine Waves").path)) ?? []).sorted()
        #expect(names == ["01 - Good.mp3"])
    }
}

/// A tiny lock for collecting events from a non-isolated callback.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

@Suite struct AlbumLayoutTests {
    @Test func multiDiscSetsGetADiscFolder() throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [1]), folder: folder, titles: ["One"])
        request.discCount = 2
        request.discNumber = 2
        let files = try Ripper.rip(request, onEvent: { _ in })
        #expect(files.first?.deletingLastPathComponent().path.hasSuffix("The Tones/Sine Waves/Disc 2") == true)
    }

    @Test func singleDiscAlbumsGetNoDiscFolder() throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try Ripper.rip(RipperTests.request(disc: FixtureDisc(trackSeconds: [1]), folder: folder, titles: ["One"]), onEvent: { _ in })
        #expect(files.first?.deletingLastPathComponent().lastPathComponent == "Sine Waves")
    }

    @Test func compilationsPutTheTrackArtistInTheFileName() throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [1, 1]), folder: folder, titles: ["Song A", "Song B"])
        request.albumArtist = "Various Artists"
        request.isCompilation = true
        request.tracks[0].artist = "Ana"
        request.tracks[1].artist = "AC/DC"
        let files = try Ripper.rip(request, onEvent: { _ in })
        #expect(files.map(\.lastPathComponent) == ["01 - Ana - Song A.mp3", "02 - AC-DC - Song B.mp3"])
        #expect(files[0].deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Various Artists")
    }
}
