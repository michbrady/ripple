import Foundation
import Testing
@testable import RippleKit

@Suite struct BurnScannerTests {
    /// Writes a real MP3 with an ID3 tag (or none when `tags` is nil).
    @discardableResult
    static func makeMP3(_ url: URL, seconds: Double = 1, tags: TrackTags?) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disc = FixtureDisc(trackSeconds: [seconds])
        let writer = try MP3TrackWriter(url: url, quality: .vbr(6), id3: tags.map(ID3Tag.make) ?? Data())
        try writer.write(try disc.readSectors(start: 0, count: disc.toc.leadOut))
        let done = DispatchSemaphore(value: 0)
        Task { try? await writer.finish(); done.signal() }
        done.wait()
        return url
    }

    static func folder() throws -> URL { try RipperTests.tempFolder() }

    @Test func readsTitleArtistLengthAndSize() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try Self.makeMP3(dir.appending(path: "a.mp3"), seconds: 2, tags: TrackTags(title: "Low A é", artist: "The Tones", trackNumber: 4, trackCount: 9))
        let item = try #require(await BurnScanner.read(file))
        #expect(item.title == "Low A é")
        #expect(item.artist == "The Tones")
        #expect(item.trackNumber == 4)
        #expect(abs(item.seconds - 2.0) < 0.15)
        #expect(item.bytes > 1_000)
    }

    @Test func aFileWithNoTagsUsesItsFileName() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try Self.makeMP3(dir.appending(path: "Plain Song.mp3"), tags: nil)
        let item = try #require(await BurnScanner.read(file))
        #expect(item.title == "Plain Song")
        #expect(item.artist.isEmpty)
        #expect(item.trackNumber == nil)
    }

    @Test func ordersByTrackNumberThenFileName() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeMP3(dir.appending(path: "z-first.mp3"), tags: TrackTags(title: "One", trackNumber: 1))
        try Self.makeMP3(dir.appending(path: "a-second.mp3"), tags: TrackTags(title: "Two", trackNumber: 2))
        try Self.makeMP3(dir.appending(path: "b-untagged.mp3"), tags: nil)
        try Self.makeMP3(dir.appending(path: "a-untagged.mp3"), tags: nil)
        let scan = await BurnScanner.scan(dir)
        #expect(scan.items.map(\.title) == ["One", "Two", "a-untagged", "b-untagged"])
    }

    @Test func includesSubfoldersAndSkipsOtherFiles() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeMP3(dir.appending(path: "Disc 1/01.mp3"), tags: TrackTags(title: "D1", trackNumber: 1))
        try Self.makeMP3(dir.appending(path: "Disc 2/01.mp3"), tags: TrackTags(title: "D2", trackNumber: 1))
        try Self.makeMP3(dir.appending(path: ".hidden/secret.mp3"), tags: TrackTags(title: "Hidden"))
        try Data("notes".utf8).write(to: dir.appending(path: "notes.txt"))
        try Data("cover".utf8).write(to: dir.appending(path: "cover.jpg"))
        try Data("not audio at all".utf8).write(to: dir.appending(path: "broken.mp3"))
        let scan = await BurnScanner.scan(dir)
        #expect(scan.items.map(\.title) == ["D1", "D2"], "folder order, hidden left out")
        #expect(scan.skipped == 3, "two other files and one broken MP3")
    }

    @Test func droppedFilesAndFoldersAreBothRead() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let single = try Self.makeMP3(dir.appending(path: "one.mp3"), tags: TrackTags(title: "One", trackNumber: 1))
        try Self.makeMP3(dir.appending(path: "Album/two.mp3"), tags: TrackTags(title: "Two", trackNumber: 1))
        let text = dir.appending(path: "readme.txt")
        try Data("x".utf8).write(to: text)
        let scan = await BurnScanner.scan(dropped: [single, dir.appending(path: "Album"), text])
        #expect(Set(scan.items.map(\.title)) == ["One", "Two"])
        #expect(scan.skipped == 1)
    }

    @Test func theSameFileReachedThroughALinkIsOneItem() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try Self.makeMP3(dir.appending(path: "a.mp3"), tags: TrackTags(title: "A"))
        let link = dir.appending(path: "link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let direct = try #require(await BurnScanner.read(file))
        let linked = try #require(await BurnScanner.read(link))
        #expect(direct.id == linked.id)
    }

    @Test func anEmptyFolderGivesNothing() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await BurnScanner.scan(dir) == BurnScan(items: [], skipped: 0))
    }
}

@Suite struct BurnPlanTests {
    static func item(_ seconds: Double, bytes: Int = 1_000_000) -> BurnItem {
        BurnItem(url: URL(fileURLWithPath: "/tmp/\(seconds)-\(bytes).mp3"), title: "t", seconds: seconds, bytes: bytes)
    }

    @Test func audioNeedsSectorsPlusTwoSecondGaps() {
        let plan = BurnPlan(items: [Self.item(60), Self.item(60)], type: .audio)
        #expect(plan.blocksNeeded == (4_500 + 150) * 2)
        #expect(plan.totalSeconds == 120)
    }

    @Test func partialSectorsRoundUp() {
        #expect(BurnPlan(items: [Self.item(1.001)], type: .audio).blocksNeeded == 76 + 150)
    }

    @Test func dataNeedsWholeBlocksPlusOverhead() {
        let plan = BurnPlan(items: [Self.item(1, bytes: 2_049), Self.item(1, bytes: 2_048)], type: .data)
        #expect(plan.blocksNeeded == 2 + 1 + 600)
    }

    @Test func withNoDiscTheLimitsAre80MinutesAndAbout700MB() {
        #expect(BurnPlan.defaultAudioBlocks == 360_000)
        #expect(BurnPlan.defaultDataBlocks == 358_400)
        let fits = BurnPlan(items: [Self.item(75 * 60)], type: .audio)
        #expect(fits.fit(on: .noDisc) == .fits)
        let over = BurnPlan(items: [Self.item(81 * 60)], type: .audio)
        if case .over(let blocks) = over.fit(on: .noDisc) { #expect(blocks > 0) } else { Issue.record("expected over") }
    }

    @Test func theBlankInTheDriveSetsTheLimit() {
        let small = FixtureBurner.blankCD(blocks: 10_000)
        let plan = BurnPlan(items: [Self.item(120)], type: .audio) // 9,150 blocks
        #expect(plan.fit(on: small) == .fits)
        let two = BurnPlan(items: [Self.item(120), Self.item(30)], type: .audio) // 12,000 + gaps
        if case .over(let blocks) = two.fit(on: small) { #expect(blocks == two.blocksNeeded - 10_000) } else { Issue.record("expected over") }
    }

    @Test func anAudioDiscDoesNotFitOnADVD() {
        let plan = BurnPlan(items: [Self.item(60)], type: .audio)
        #expect(plan.fit(on: FixtureBurner.blankDVD()) == .wrongMedia("An Audio Disc needs a blank CD-R. This disc is a DVD-R."))
    }

    @Test func anMP3DiscFitsOnADVDAndCountsMegabytes() {
        let plan = BurnPlan(items: [Self.item(60, bytes: 1_000_000_000)], type: .data) // about 954 MB
        #expect(plan.fit(on: FixtureBurner.blankDVD()) == .fits)
        if case .over = plan.fit(on: FixtureBurner.blankCD()) {} else { Issue.record("a CD is too small for 954 MB") }
        #expect(plan.usedText(on: FixtureBurner.blankDVD()).hasSuffix("of 4488 MB"))
    }

    @Test func textsNameTheAmounts() {
        let audio = BurnPlan(items: [Self.item(60 * 47)], type: .audio)
        #expect(audio.usedText(on: .noDisc) == "48 min of 80 min")
        #expect(audio.overText(blocks: 75 * 60 * 12 - 1) == "12 min over")
        let data = BurnPlan(items: [Self.item(60, bytes: 310 * 1_048_576)], type: .data)
        #expect(data.overText(blocks: 85 * 512) == "85 MB over")
    }

    @Test func nothingToBurnIsItsOwnAnswer() {
        #expect(BurnPlan(items: [], type: .audio).fit(on: .noDisc) == .nothingToBurn)
        #expect(BurnPlan(items: [], type: .audio).blocksNeeded == 0)
    }

    @Test func theFractionGrowsWithTheList() {
        let half = BurnPlan(items: [Self.item(40 * 60)], type: .audio)
        #expect(abs(half.usedFraction(on: .noDisc) - 0.5) < 0.05)
    }
}

@Suite struct FixtureBurnerTests {
    static let job = BurnJob(type: .audio, files: [URL(fileURLWithPath: "/tmp/a.mp3")], volumeName: "Mix")

    @Test func burnsAndReportsEveryStageInOrder() async throws {
        let burner = FixtureBurner(state: FixtureBurner.blankCD())
        let stages = Locked<[BurnStage]>([])
        try await burner.burn(Self.job) { stage in stages.withLock { $0.append(stage) } }
        let seen = stages.withLock { $0 }
        #expect(seen.first == .preparing)
        #expect(seen.last == .finishing)
        #expect(seen.contains(.burning(0.5)) && seen.contains(.burning(1.0)))
        #expect(burner.jobs == [Self.job])
    }

    @Test func cancellingBeforeWritingLeavesTheDiscUntouched() async throws {
        let burner = FixtureBurner(state: FixtureBurner.blankCD())
        burner.stepDelay = .milliseconds(200)
        let task = Task { try await burner.burn(Self.job) { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(burner.jobs.isEmpty)
    }

    @Test func noDiscMeansNoBurn() async {
        let burner = FixtureBurner(state: .noDisc)
        await #expect(throws: BurnError.noDisc) { try await burner.burn(Self.job) { _ in } }
    }

    @Test func aDriveErrorIsReportedOnceThenCleared() async throws {
        let burner = FixtureBurner(state: FixtureBurner.blankCD())
        burner.failNextBurn = .driveError("write failed")
        await #expect(throws: BurnError.driveError("write failed")) { try await burner.burn(Self.job) { _ in } }
        try await burner.burn(Self.job) { _ in }
        #expect(burner.jobs.count == 1)
    }

    @Test func stateChangesAreAnnounced() async throws {
        let burner = FixtureBurner(state: .noDisc)
        var stream = burner.stateChanges().makeAsyncIterator()
        burner.set(FixtureBurner.blankCD())
        #expect(await stream.next() == FixtureBurner.blankCD())
        burner.eject()
        #expect(await stream.next() == .noDisc)
        #expect(burner.ejectCount == 1)
    }

    @Test func burnErrorsHavePlainWords() {
        #expect(BurnError.noDisc.errorDescription == "There is no blank disc in the drive.")
        #expect(BurnError.driveError("x").errorDescription?.contains("drive") == true)
        #expect(BurnError.discRejected("x").errorDescription?.contains("rejected") == true)
    }
}
