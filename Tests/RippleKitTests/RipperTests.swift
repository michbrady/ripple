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

    @Test func ripsEveryTrackToNamedFiles() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = FixtureDisc()
        let files = try await Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["Low A", "High/C", "Same"]), onEvent: { _ in })
        let names = files.map(\.lastPathComponent)
        #expect(names == ["01 - Low A.mp3", "02 - High-C.mp3", "03 - Same.mp3"])
        #expect(files.allSatisfy { $0.deletingLastPathComponent().path.hasSuffix("The Tones/Sine Waves") })
        let file = try AVAudioFile(forReading: files[1])
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3.0) < 0.15)
    }

    @Test func uncheckedTracksMakeNoFiles() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = Self.request(disc: FixtureDisc(), folder: folder, titles: ["A", "B", "C"])
        request.tracks[1].include = false
        let files = try await Ripper.rip(request, onEvent: { _ in })
        #expect(files.map(\.lastPathComponent) == ["01 - A.mp3", "03 - C.mp3"])
    }

    @Test func reportsProgressForEachTrack() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Locked<[RipEvent]>([])
        _ = try await Ripper.rip(Self.request(disc: FixtureDisc(trackSeconds: [1]), folder: folder, titles: ["Only"])) { event in
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
            try await Ripper.rip(request) { event in
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

    @Test func anUnreadableSectorSavesTheTrackAndFlagsIt() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = FixtureDisc(trackSeconds: [1, 1], badSectors: [100])
        let events = Locked<[RipEvent]>([])
        let files = try await Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["Good", "Scratched"])) { event in
            events.withLock { $0.append(event) }
        }
        #expect(files.map(\.lastPathComponent) == ["01 - Good.mp3", "02 - Scratched.mp3"])
        let seen = events.withLock { $0 }
        #expect(seen.contains(.needsAttention(track: 1, unreadable: 1, suspect: 0)))
        #expect(!seen.contains { if case .needsAttention(let track, _, _) = $0 { track == 0 } else { false } }, "the clean track is not flagged")
        let file = try AVAudioFile(forReading: files[1])
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 1.0) < 0.15, "the file keeps its full length")
    }

    @Test func aSectorThatFailsTwiceIsRetriedAndNotFlagged() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = FixtureDisc(trackSeconds: [1, 1], faults: .init(failFirst: [100: 2]))
        let events = Locked<[RipEvent]>([])
        _ = try await Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["A", "B"])) { event in
            events.withLock { $0.append(event) }
        }
        #expect(!events.withLock { $0 }.contains { if case .needsAttention = $0 { true } else { false } })
    }

    @Test func aRetryReplacesTheOldFileInPlace() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let faults = FixtureDisc.Faults(failFirst: [100: 8])
        let disc = FixtureDisc(trackSeconds: [1, 1], faults: faults)
        let first = try await Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["A", "B"]), onEvent: { _ in })
        let before = try Data(contentsOf: first[1])

        var again = Self.request(disc: disc, folder: folder, titles: ["A", "B"])
        again.tracks[0].include = false
        again.replacing = [1: first[1]]
        let events = Locked<[RipEvent]>([])
        let second = try await Ripper.rip(again) { event in events.withLock { $0.append(event) } }
        #expect(second == [first[1]], "the same file")
        #expect(!events.withLock { $0 }.contains { if case .needsAttention = $0 { true } else { false } }, "the retry read it cleanly")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: first[1].deletingLastPathComponent().path)) ?? []).sorted()
        #expect(names == ["01 - A.mp3", "02 - B.mp3"], "no duplicate: \(names)")
        #expect(try Data(contentsOf: first[1]) != before, "the file was rebuilt")
    }

    @Test func aCancelledRetryKeepsTheOldFile() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = FixtureDisc(trackSeconds: [1, 20])
        let first = try await Ripper.rip(Self.request(disc: disc, folder: folder, titles: ["A", "B"]), onEvent: { _ in })
        let before = try Data(contentsOf: first[1])
        var again = Self.request(disc: disc, folder: folder, titles: ["A", "B"])
        again.tracks[0].include = false
        again.replacing = [1: first[1]]
        let request = again
        let task = Task.detached {
            try await Ripper.rip(request) { event in
                if case .progress(_, let fraction) = event, fraction > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try Data(contentsOf: first[1]) == before)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: first[1].deletingLastPathComponent().path)) ?? []).sorted()
        #expect(names == ["01 - A.mp3", "02 - B.mp3"], "no partial file left: \(names)")
    }
}

@Suite struct SectorReaderTests {
    static let pristine = FixtureDisc(trackSeconds: [4])
    static func expected(_ start: Int, _ count: Int) throws -> Data { try pristine.readSectors(start: start, count: count) }

    @Test func aCleanDiscReadsAsIs() throws {
        var reader = SectorReader(disc: FixtureDisc(trackSeconds: [4]))
        #expect(try reader.read(start: 10, count: 26) == Self.expected(10, 26))
        #expect(reader.issues.isClean && reader.issues.retries == 0)
    }

    @Test func aReadThatFailsTwiceSucceedsOnTheThirdTry() throws {
        let disc = FixtureDisc(trackSeconds: [4], faults: .init(failFirst: [20: 2]))
        var reader = SectorReader(disc: disc, verify: false)
        #expect(try reader.read(start: 10, count: 26) == Self.expected(10, 26))
        #expect(reader.issues.isClean)
        #expect(reader.issues.retries == 2)
    }

    @Test func retriesAreLimited() throws {
        let disc = FixtureDisc(trackSeconds: [4], faults: .init(failFirst: [20: 1_000]))
        var reader = SectorReader(disc: disc, verify: false, maxRetries: 3)
        _ = try reader.read(start: 10, count: 26)
        // 4 tries at the chunk, then 4 tries at sector 20 alone.
        #expect(reader.issues.retries == 6)
        #expect(reader.issues.unreadable == [20])
    }

    @Test func anUnreadableSectorBecomesSilenceAndTheRestSurvives() throws {
        let disc = FixtureDisc(trackSeconds: [4], badSectors: [20])
        var reader = SectorReader(disc: disc)
        let data = try reader.read(start: 10, count: 26)
        let good = try Self.expected(10, 26)
        let bytes = SectorReader.sectorBytes
        #expect(data.count == good.count)
        #expect(data[(20 - 10) * bytes ..< (21 - 10) * bytes] == Data(count: bytes), "silence in the bad sector")
        #expect(data[0 ..< (20 - 10) * bytes] == good[0 ..< (20 - 10) * bytes])
        #expect(data[(21 - 10) * bytes ..< data.count] == good[(21 - 10) * bytes ..< good.count])
        #expect(reader.issues.unreadable == [20])
        #expect(reader.issues.suspect.isEmpty)
    }

    @Test func aReadThatReturnsWrongDataWithoutAnErrorIsCaughtAndRepaired() throws {
        let disc = FixtureDisc(trackSeconds: [4], faults: .init(corruptFirst: [20: 1]))
        var reader = SectorReader(disc: disc, verify: true)
        #expect(try reader.read(start: 10, count: 26) == Self.expected(10, 26))
        #expect(reader.issues.isClean)
    }

    @Test func withoutCheckingWrongDataGetsThrough() throws {
        let disc = FixtureDisc(trackSeconds: [4], faults: .init(corruptFirst: [20: 1]))
        var reader = SectorReader(disc: disc, verify: false)
        #expect(try reader.read(start: 10, count: 26) != Self.expected(10, 26))
    }

    @Test func readsThatNeverAgreeAreMarkedSuspect() throws {
        let disc = FixtureDisc(trackSeconds: [4], faults: .init(corruptFirst: [20: 1_000]))
        var reader = SectorReader(disc: disc, verify: true)
        let data = try reader.read(start: 10, count: 26)
        #expect(reader.issues.suspect == [20])
        #expect(reader.issues.unreadable.isEmpty)
        #expect(data.count == 26 * SectorReader.sectorBytes)
    }

    @Test func checkingReadsEverythingMoreThanOnce() throws {
        // 40 seconds is 3,000 sectors, more than the 2,000-sector hop that clears the drive's cache.
        let plain = FixtureDisc(trackSeconds: [40])
        var one = SectorReader(disc: plain, verify: false)
        _ = try one.read(start: 0, count: 26)
        let checked = FixtureDisc(trackSeconds: [40])
        var two = SectorReader(disc: checked, verify: true)
        _ = try two.read(start: 0, count: 26)
        #expect(plain.faults.reads == 1)
        #expect(checked.faults.reads == 3, "two reads and a cache-clearing read: \(checked.faults.reads)")
    }

    @Test func aShortDiscSkipsTheCacheClearingRead() throws {
        let disc = FixtureDisc(trackSeconds: [4])
        var reader = SectorReader(disc: disc, verify: true)
        _ = try reader.read(start: 0, count: 26)
        #expect(disc.faults.reads == 2)
    }

    @Test func aRangeOutsideTheDiscThrows() {
        var reader = SectorReader(disc: FixtureDisc(trackSeconds: [1]))
        #expect(throws: DiscError.outOfRange) { _ = try reader.read(start: 70, count: 26) }
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
    @Test func multiDiscSetsGetADiscFolder() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [1]), folder: folder, titles: ["One"])
        request.discCount = 2
        request.discNumber = 2
        let files = try await Ripper.rip(request, onEvent: { _ in })
        #expect(files.first?.deletingLastPathComponent().path.hasSuffix("The Tones/Sine Waves/Disc 2") == true)
    }

    @Test func singleDiscAlbumsGetNoDiscFolder() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await Ripper.rip(RipperTests.request(disc: FixtureDisc(trackSeconds: [1]), folder: folder, titles: ["One"]), onEvent: { _ in })
        #expect(files.first?.deletingLastPathComponent().lastPathComponent == "Sine Waves")
    }

    @Test func compilationsPutTheTrackArtistInTheFileName() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [1, 1]), folder: folder, titles: ["Song A", "Song B"])
        request.albumArtist = "Various Artists"
        request.isCompilation = true
        request.tracks[0].artist = "Ana"
        request.tracks[1].artist = "AC/DC"
        let files = try await Ripper.rip(request, onEvent: { _ in })
        #expect(files.map(\.lastPathComponent) == ["01 - Ana - Song A.mp3", "02 - AC-DC - Song B.mp3"])
        #expect(files[0].deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Various Artists")
    }
}

@Suite struct FormatTests {
    static func rip(format: RipFormat, quality: MP3Encoder.Quality = .vbr(2), seconds: Double = 3) async throws -> (files: [URL], folder: URL) {
        let folder = try RipperTests.tempFolder()
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [seconds]), folder: folder, titles: ["Tone"])
        request.format = format
        request.quality = quality
        return (try await Ripper.rip(request, onEvent: { _ in }), folder)
    }

    @Test func m4aFilesAreNamedAndReadable() async throws {
        let (files, folder) = try await Self.rip(format: .m4a)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(files.map(\.lastPathComponent) == ["01 - Tone.m4a"])
        let file = try AVAudioFile(forReading: files[0])
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 3.0) < 0.15, "decoded length \(seconds) s")
        // An MP4 container starts with an "ftyp" box.
        let head = try Data(contentsOf: files[0]).prefix(12)
        #expect(String(decoding: head.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp")
    }

    @Test func m4aIsAboutTheRequestedBitRate() async throws {
        let (files, folder) = try await Self.rip(format: .m4a, seconds: 4)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = try Data(contentsOf: files[0]).count
        // 256 kbps for 4 s is 128 000 bytes. A pure tone compresses a little better, so allow a wide band.
        #expect(bytes > 20_000 && bytes < 160_000, "\(bytes) bytes")
    }

    @Test func mp3FilesUseTheExtensionAndKeepTheQuality() async throws {
        let (low, lowFolder) = try await Self.rip(format: .mp3, quality: .cbr(128), seconds: 4)
        let (high, highFolder) = try await Self.rip(format: .mp3, quality: .cbr(320), seconds: 4)
        defer { try? FileManager.default.removeItem(at: lowFolder); try? FileManager.default.removeItem(at: highFolder) }
        #expect(low[0].pathExtension == "mp3")
        let lowSize = try Data(contentsOf: low[0]).count
        let highSize = try Data(contentsOf: high[0]).count
        #expect(abs(Double(lowSize) - 64_000) < 6_000, "128 kbps for 4 s: \(lowSize) bytes")
        #expect(abs(Double(highSize) - 160_000) < 12_000, "320 kbps for 4 s: \(highSize) bytes")
    }

    @Test func cancelledM4ARipLeavesNoPartialFile() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [30]), folder: folder, titles: ["Long"])
        request.format = .m4a
        let task = Task.detached {
            try await Ripper.rip(request) { event in
                if case .progress(_, let fraction) = event, fraction > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(left.isEmpty, "left behind: \(left)")
    }
}
