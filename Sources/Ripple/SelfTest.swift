import AppKit
import AVFoundation
import Foundation
import ImageIO
import RippleKit
import UniformTypeIdentifiers

/// Self-test for agents: runs the app's real functions on a made-up disc,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Ripple-self.store ~/Applications/Ripple.app/Contents/MacOS/Ripple --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
/// It never touches a drive: real-disc checks are manual (see docs/STORIES.md).
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel, burn: BurnModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let fm = FileManager.default
            let out = fm.temporaryDirectory.appending(path: "ripple-self-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: out) }
            model.outputFolder = out

            // S-001: no disc shows the empty state.
            model.lookup = FixtureLookup(mode: .none)
            model.showSnapshot(.empty)
            check("no disc shows the empty state", model.phase == .empty && !model.hasDisc)

            // S-003: a disc shows one row per track, titled "Track NN".
            model.load(FixtureDisc(), bsdName: nil)
            await wait(until: { model.lookupState == .notFound })
            check("a disc shows its tracks", model.phase == .ready && model.rows.count == 3)
            check("no match says so and keeps the track names", model.lookupState == .notFound && model.albumTitle.isEmpty)
            check("tracks start as Track 01, Track 02, Track 03", model.rows.map(\.title) == ["Track 01", "Track 02", "Track 03"])
            check("lengths come from the table of contents", model.rows.map { Int($0.seconds.rounded()) } == [2, 3, 2])
            check("the disc ID is 28 characters", model.disc?.toc.discID.count == 28)

            // S-008: with nothing checked, Rip does nothing.
            for index in model.rows.indices { model.rows[index].include = false }
            model.rip()
            check("with nothing checked, Rip does nothing", model.phase == .ready && model.checkedCount == 0)
            for index in model.rows.indices { model.rows[index].include = true }

            // S-008: unchecked tracks make no files. S-007: files land in the Output Folder. S-006: named by title.
            model.rows[1].include = false
            check("the Rip button counts the checked tracks", model.checkedCount == 2)
            model.setTitle("Intro / Overture", row: model.rows[0].id)
            model.rip()
            check("Rip starts ripping", model.phase == .ripping)
            await wait(until: { !model.isRipping })
            let album = out.appending(path: "Unknown Artist/Unknown Album")
            let names = ((try? fm.contentsOfDirectory(atPath: album.path)) ?? []).sorted()
            check("ripping makes one MP3 per checked track, named by title",
                  names == ["01 - Intro - Overture.mp3", "03 - Track 03.mp3"], "\(names)")
            check("a finished rip shows the done state", { if case .done = model.phase { true } else { false } }())
            check("rows show Done", model.rows.filter { $0.status == .done }.count == 2)

            // S-009: Cancel keeps finished tracks and leaves no half file.
            model.eject()
            check("eject returns to the empty state", model.phase == .empty && model.rows.isEmpty)
            model.load(FixtureDisc(trackSeconds: [1, 40, 1]), bsdName: nil)
            model.setAlbumTitle("Cancelled")
            model.rip()
            await wait(until: { if case .ripping(let f) = model.rows[1].status { f > 0.1 } else { false } })
            model.cancel()
            await wait(until: { !model.isRipping })
            let cancelled = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "Unknown Artist/Cancelled").path)) ?? []).sorted()
            check("Cancel keeps finished tracks and removes the partial file", cancelled == ["01 - Track 01.mp3"], "\(cancelled)")
            check("Cancel returns to the track list", model.phase == .ready)

            await lookupChecks(model: model, out: out)
            await formatChecks(model: model, out: out)
            await tagChecks(model: model, out: out)
            await attentionChecks(model: model, out: out)
            await burnChecks(burn: burn, out: out)
            realDriveChecks()
            coverPrepChecks()

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// S-026 to S-033: burn mode, on real MP3 files and a stand-in burner.
    private static func burnChecks(burn: BurnModel, out: URL) async {
        let fm = FileManager.default
        guard let burner = burn.burner as? FixtureBurner else {
            check("the self-test uses the stand-in burner", false)
            return
        }

        // Real MP3 files, made by the ripper: three tracks of two seconds, tagged One, Two, Three.
        let source = out.appending(path: "burn-source", directoryHint: .isDirectory)
        let album = FixtureDisc(trackSeconds: [2, 2, 2])
        let request = RipRequest(disc: album, tracks: ["One", "Two", "Three"].enumerated().map { RipTrack(number: $0.offset + 1, title: $0.element, artist: "The Tones") },
                                 albumArtist: "The Tones", album: "Mix", folder: source, quality: .vbr(6), verify: false)
        _ = try? await Ripper.rip(request, onEvent: { _ in })
        let folder = source.appending(path: "The Tones/Mix", directoryHint: .isDirectory)
        try? Data("notes".utf8).write(to: folder.appending(path: "notes.txt"))

        // S-026, S-027: choose a folder, and the MP3 files are listed in order.
        burn.clear()
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.deviceState == FixtureBurner.blankCD() })
        burn.load(folder: folder)
        await wait(until: { !burn.isScanning && !burn.items.isEmpty })
        check("a folder of MP3 files is listed in order", burn.items.map(\.title) == ["One", "Two", "Three"], "\(burn.items.map(\.title))")
        check("each file shows its artist and length", burn.items.allSatisfy { $0.artist == "The Tones" && abs($0.seconds - 2) < 0.2 })
        check("a file that is not MP3 is counted as skipped", burn.skipped == 1)
        check("the volume name is the folder name", burn.volumeName == "Mix")

        // Dropping files adds them once.
        await burn.add(dropped: [folder.appending(path: "02 - Two.mp3"), folder.appending(path: "notes.txt")])
        check("a dropped file that is already listed is not added twice", burn.items.count == 3)
        check("a dropped file that is not MP3 is counted as skipped", burn.skipped == 2)

        // S-028: reorder, remove, undo.
        let undo = UndoManager()
        undo.groupsByEvent = false
        burn.undoManager = undo
        undo.beginUndoGrouping()
        burn.move(from: IndexSet(integer: 2), to: 0)
        undo.endUndoGrouping()
        check("dragging a row changes the burn order", burn.items.map(\.title) == ["Three", "One", "Two"], "\(burn.items.map(\.title))")
        undo.beginUndoGrouping()
        burn.remove(ids: [burn.items[1].id])
        undo.endUndoGrouping()
        check("Delete removes the selected file", burn.items.map(\.title) == ["Three", "Two"])
        undo.undo()
        check("Undo brings the removed file back", burn.items.map(\.title) == ["Three", "One", "Two"], "\(burn.items.map(\.title))")
        undo.undo()
        check("Undo brings back the old order", burn.items.map(\.title) == ["One", "Two", "Three"])

        // S-029: capacity.
        burn.type = .audio
        burner.set(FixtureBurner.blankCD(blocks: 10_000))
        await wait(until: { burn.deviceState == FixtureBurner.blankCD(blocks: 10_000) })
        check("three 2-second files fit on a small blank", burn.fit == .fits && burn.canBurn)
        burner.set(FixtureBurner.blankCD(blocks: 500))
        await wait(until: { burn.deviceState == FixtureBurner.blankCD(blocks: 500) })
        var isOver = false
        if case .over = burn.fit { isOver = true }
        check("files that do not fit say so and block the Burn button", isOver && !burn.canBurn && burn.fitMessage?.hasPrefix("Remove ") == true, "\(burn.fitMessage ?? "nil")")
        burner.set(FixtureBurner.blankDVD())
        await wait(until: { burn.deviceState == FixtureBurner.blankDVD() })
        check("an Audio Disc does not go on a DVD", !burn.canBurn && burn.fitMessage == "An Audio Disc needs a blank CD-R. This disc is a DVD-R.", "\(burn.fitMessage ?? "nil")")
        burn.type = .data
        check("an MP3 Disc does go on a DVD", burn.canBurn)
        burn.type = .audio

        // S-030: the drive and the disc.
        for (state, words) in [(BurnDeviceState.noDrive, "Connect a USB burner"), (.noDisc, "Insert a blank CD-R."),
                               (.notBlank(label: "CD-RW", rewritable: true), "Erase it in Disk Utility"),
                               (.notBlank(label: "CD-R", rewritable: false), "Insert a blank disc.")] {
            burner.set(state)
            await wait(until: { burn.deviceState == state })
            check("the drive line for \(state) says what to do", burn.deviceLine.contains(words) && !burn.canBurn, burn.deviceLine)
        }

        // S-031: burn an Audio Disc. The files go to the burner in list order.
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.canBurn })
        burn.burn()
        check("Burn starts burning", burn.isBurning)
        await wait(until: { burn.phase == .done })
        check("the burn finishes", burn.phase == .done)
        let job = burner.jobs.last
        check("an Audio Disc job carries the files in list order", job?.type == .audio && job?.files == burn.items.map(\.url))
        check("the job names the volume", job?.volumeName == "Mix")

        // S-033: burn an MP3 Disc on a DVD.
        burn.tryAgain()
        burn.type = .data
        burner.set(FixtureBurner.blankDVD())
        await wait(until: { burn.canBurn })
        burn.burn()
        await wait(until: { burn.phase == .done })
        check("an MP3 Disc job is marked as data", burner.jobs.last?.type == .data && burner.jobs.count == 2)
        burn.tryAgain()
        burn.type = .audio

        // S-032: cancel before writing, no cancel after, and a failed burn.
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.canBurn })
        burner.stepDelay = .milliseconds(300)
        let before = burner.jobs.count
        burn.burn()
        await wait(until: { burn.phase == .burning(.preparing) })
        check("Cancel is offered while preparing", burn.canCancel)
        burn.cancel()
        await wait(until: { burn.phase == .editing })
        check("Cancel before writing leaves the disc untouched", burn.phase == .editing && burner.jobs.count == before)

        burner.stepDelay = .milliseconds(60)
        burn.burn()
        await wait(until: { if case .burning(.burning) = burn.phase { true } else { false } })
        check("Cancel is gone once writing starts", !burn.canCancel)
        check("the quit prompt warns that stopping ruins the disc", burn.stopPrompt.detail == "Stopping now ruins the disc.", burn.stopPrompt.detail)
        await wait(until: { burn.phase == .done })

        burn.tryAgain()
        burner.stepDelay = .milliseconds(5)
        burner.failNextBurn = .driveError("The disc could not be written.")
        burn.burn()
        await wait(until: { if case .failed = burn.phase { true } else { false } })
        var message = ""
        if case .failed(let text) = burn.phase { message = text }
        check("a failed burn says why", message.contains("The disc could not be written."), message)
        burn.tryAgain()
        check("Try Again returns to the list", burn.phase == .editing && burn.items.count == 3)

        burn.eject()
        check("Eject asks the burner to eject", burner.ejectCount == 1)
        burn.clear()
        burner.set(FixtureBurner.blankCD())
    }

    /// Reads the Mac's real burner through DiscRecordingBurner. Runs only with RIPPLE_REAL_DRIVE=1, and never writes.
    private static func realDriveChecks() {
        guard ProcessInfo.processInfo.environment["RIPPLE_REAL_DRIVE"] == "1" else { return }
        let real = DiscRecordingBurner()
        let state = real.state()
        print("INFO real drive: \(real.deviceName ?? "none") -> \(state)")
        check("the real burner reports a drive when one is connected", (real.deviceName != nil) == (state != .noDrive))
        if case .ready(let media) = state {
            check("a blank disc in the real drive reports a type and free space", !media.label.isEmpty && media.blocksFree > 0, "\(media)")
        }
    }

    /// S-020, S-021: a scratched disc is saved, flagged, and can be ripped again.
    private static func attentionChecks(model: AppModel, out: URL) async {
        let fm = FileManager.default
        model.eject()
        model.lookup = FixtureLookup(mode: .none)
        model.format = .mp3
        model.verifyReads = true
        // Sector 100 is in track 2. It fails 8 times: more than one rip's retries, fewer than two rips'.
        let disc = FixtureDisc(trackSeconds: [1, 1, 1], faults: .init(failFirst: [100: 8]))
        model.load(disc, bsdName: nil)
        model.setAlbumArtist("Scratched")
        model.setAlbumTitle("Disc")
        model.rip()
        await wait(until: { !model.isRipping })
        let folder = out.appending(path: "Scratched/Disc")
        func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        check("a track that cannot be read cleanly is still saved", names() == ["01 - Track 01.mp3", "02 - Track 02.mp3", "03 - Track 03.mp3"], "\(names())")
        check("that track is marked Needs Attention", model.rows[1].status == .needsAttention(unreadable: 1, suspect: 0), "\(model.rows[1].status)")
        check("the other tracks are done", model.rows[0].status == .done && model.rows[2].status == .done)
        check("the page counts the tracks that need attention", model.needsAttentionCount == 1 && model.rippedCount == 3)
        let before = (try? Data(contentsOf: folder.appending(path: "02 - Track 02.mp3"))) ?? Data()

        model.retry(model.rows[1].id)
        check("Retry starts ripping again", model.phase == .ripping)
        await wait(until: { !model.isRipping })
        let after = (try? Data(contentsOf: folder.appending(path: "02 - Track 02.mp3"))) ?? Data()
        check("Retry rips the track cleanly this time", model.rows[1].status == .done && model.needsAttentionCount == 0, "\(model.rows[1].status)")
        check("Retry replaces the file and adds no copy", names().count == 3 && after != before)
        check("the page is done again after a Retry", { if case .done = model.phase { true } else { false } }())

        // With checking off, a disc that returns wrong data goes unnoticed; with it on, it is repaired.
        for verify in [false, true] {
            model.eject()
            model.verifyReads = verify
            let faults = FixtureDisc.Faults(corruptFirst: [100: 1])
            model.load(FixtureDisc(trackSeconds: [1, 1, 1], faults: faults), bsdName: nil)
            model.setAlbumArtist("Corrupt")
            model.setAlbumTitle(verify ? "Checked" : "Unchecked")
            model.rip()
            await wait(until: { !model.isRipping })
            // Three one-second tracks are 3 chunks of up to 26 sectors each: 9 reads if nothing is repeated.
            let reads = faults.reads
            check(verify ? "Check for Errors reads more than once" : "without Check for Errors each part is read once",
                  verify ? reads > 9 : reads == 9, "\(reads) reads")
        }
        model.verifyReads = true
        model.eject()
    }

    /// S-019: what the model shows ends up in the files.
    private static func tagChecks(model: AppModel, out: URL) async {
        for format in RipFormat.allCases {
            model.eject()
            model.lookup = FixtureLookup(mode: .found)
            model.format = format
            model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
            await wait(until: { model.lookupState == .found && model.coverData != nil })
            model.chooseMatch(id: "fixture-2")
            model.setAlbumTitle("Tagged \(format.title)")
            model.rip()
            await wait(until: { !model.isRipping })
            let folder = out.appending(path: "The Tones/Tagged \(format.title)/Disc 2")
            let file = folder.appending(path: "01 - Low A (Live).\(format.fileExtension)")
            let items = (try? await AVURLAsset(url: file).load(.metadata)) ?? []
            func string(_ id: AVMetadataIdentifier) async -> String? {
                try? await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.load(.stringValue)
            }
            func data(_ id: AVMetadataIdentifier) async -> Data? {
                try? await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.load(.dataValue)
            }
            let mp3 = format == .mp3
            let title = await string(mp3 ? .id3MetadataTitleDescription : .iTunesMetadataSongName)
            let album = await string(mp3 ? .id3MetadataAlbumTitle : .iTunesMetadataAlbum)
            let picture = await data(mp3 ? .id3MetadataAttachedPicture : .iTunesMetadataCoverArt)
            check("a ripped \(format.title) carries the title and album", title == "Low A (Live)" && album == "Tagged \(format.title)", "\(title ?? "nil") / \(album ?? "nil")")
            check("a ripped \(format.title) carries the cover", picture == model.coverData && picture != nil)
            if mp3 {
                let set = await string(.id3MetadataPartOfASet)
                let recorded = await string(.id3MetadataRecordingTime)
                let year = await string(.id3MetadataYear)
                check("a ripped MP3 carries disc 2 of 2 and the year", set == "2/2" && (recorded ?? year) != nil, "\(set ?? "nil") / \(recorded ?? year ?? "nil")")
            } else {
                let disc = await data(.iTunesMetadataDiscNumber).map { [UInt8]($0) }
                check("a ripped M4A carries disc 2 of 2", disc == [0, 0, 0, 2, 0, 2], "\(String(describing: disc))")
            }
        }
        model.eject()
    }

    /// Covers are kept when they are small JPEG or PNG, and converted otherwise.
    private static func coverPrepChecks() {
        func image(_ size: Int, as type: UTType) -> Data {
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
            return data as Data
        }
        func width(_ data: Data) -> Int? {
            (CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        }
        let small = image(500, as: .png)
        check("a small PNG cover is kept as it is", CoverPrep.prepared(small) == small)
        let big = image(2_400, as: .png)
        let shrunk = CoverPrep.prepared(big)
        check("a huge cover becomes a JPEG of at most 1,000 pixels", shrunk.flatMap(width) == 1_000 && shrunk?.prefix(2) == Data([0xFF, 0xD8]))
        let tiff = image(300, as: .tiff)
        check("a TIFF cover becomes a JPEG", CoverPrep.prepared(tiff)?.prefix(2) == Data([0xFF, 0xD8]))
        check("bytes that are not an image are refused", CoverPrep.prepared(Data("not an image".utf8)) == nil)
    }

    /// S-007, S-016 to S-018: Output Folder, format, and quality are saved and used.
    private static func formatChecks(model: AppModel, out: URL) async {
        let fm = FileManager.default

        // A fresh settings store starts with MP3 and the Music folder.
        let suite = "com.michael.ripple.selftest-settings"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let fresh = AppModel(defaults: defaults)
        check("a fresh install defaults to MP3 with variable quality", fresh.format == .mp3 && fresh.mp3Quality == .vbr(2))
        check("a fresh install checks for errors", fresh.verifyReads)
        fresh.verifyReads = false
        check("the Check for Errors setting survives a restart", !AppModel(defaults: defaults).verifyReads)
        fresh.verifyReads = true

        // A new AppModel on the same store is a restart.
        fresh.format = .m4a
        fresh.mp3Quality = .cbr(192)
        fresh.outputFolder = out
        let restarted = AppModel(defaults: defaults)
        check("the format survives a restart", restarted.format == .m4a)
        check("the MP3 quality survives a restart", restarted.mp3Quality == .cbr(192))
        check("the Output Folder survives a restart", restarted.outputFolder == out)
        defaults.set("nonsense", forKey: "format")
        defaults.set("nonsense", forKey: "mp3.quality")
        let damaged = AppModel(defaults: defaults)
        check("unreadable saved settings fall back to the defaults", damaged.format == .mp3 && damaged.mp3Quality == .vbr(2))
        UserDefaults().removePersistentDomain(forName: suite)
        AppModel.current = model

        // The chosen format decides the file extension.
        model.eject()
        model.lookup = FixtureLookup(mode: .none)
        model.format = .m4a
        model.setAlbumArtist("Format Test")
        model.setAlbumTitle("M4A")
        model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
        model.setAlbumArtist("Format Test")
        model.setAlbumTitle("M4A")
        model.rip()
        await wait(until: { !model.isRipping })
        let m4a = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "Format Test/M4A").path)) ?? []).sorted()
        check("M4A makes .m4a files", m4a == ["01 - Track 01.m4a", "02 - Track 02.m4a"], "\(m4a)")

        model.eject()
        model.format = .mp3
        model.mp3Quality = .cbr(320)
        model.load(FixtureDisc(trackSeconds: [4]), bsdName: nil)
        model.setAlbumArtist("Format Test")
        model.setAlbumTitle("MP3 320")
        model.rip()
        await wait(until: { !model.isRipping })
        let file = out.appending(path: "Format Test/MP3 320/01 - Track 01.mp3")
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        check("the MP3 quality setting reaches the encoder", abs(size - 160_000) < 12_000, "\(size) bytes")
        model.eject()
    }

    /// S-010 to S-015: the album lookup, matches, edits, cover, multi-disc, compilations.
    private static func lookupChecks(model: AppModel, out: URL) async {
        let fm = FileManager.default

        // S-010: titles, album, and artist come from the best match.
        model.eject()
        model.lookup = FixtureLookup(mode: .found)
        model.load(FixtureDisc(), bsdName: nil)
        await wait(until: { model.lookupState == .found })
        check("a lookup fills the album and artist", model.albumTitle == "Sine Waves" && model.albumArtist == "The Tones")
        check("a lookup replaces Track NN with real titles", model.rows.map(\.title) == ["Low A", "Rising Fifth", "High/C"])
        check("the exact match comes first", model.matches.first?.isExactDiscMatch == true && model.matches.count == 2)

        // S-012: the cover loads.
        await wait(until: { model.coverImage != nil })
        check("the cover loads from the match", model.coverImage != nil)

        // S-011 and S-013: choosing another match keeps what the user typed, and only that.
        model.setTitle("My Title", row: model.rows[1].id)
        model.chooseMatch(id: "fixture-2")
        check("another match changes the titles the user did not edit", model.rows[0].title == "Low A (Live)")
        check("another match sets disc N of M", model.discNumber == 2 && model.discCount == 2)
        model.setAlbumTitle("My Album")
        model.chooseMatch(id: "fixture-1")

        // S-014: a dropped image replaces the cover, and stays through a new match.
        let png = fm.temporaryDirectory.appending(path: "ripple-cover-\(UUID().uuidString).png")
        try? FixtureLookup.coverPNG().write(to: png)
        let before = model.coverImage
        check("dropping an image replaces the cover", model.setCover(from: png) && model.coverImage !== before)
        let custom = model.coverImage
        model.chooseMatch(id: "fixture-2")
        try? await Task.sleep(for: .milliseconds(300))
        check("a custom cover stays when another match is chosen", model.coverImage === custom)
        let text = fm.temporaryDirectory.appending(path: "ripple-\(UUID().uuidString).txt")
        try? Data("hello".utf8).write(to: text)
        check("a file that is not an image is refused", !model.setCover(from: text))
        try? fm.removeItem(at: png)
        try? fm.removeItem(at: text)

        // S-013: with no network, everything is still editable.
        model.eject()
        model.lookup = FixtureLookup(mode: .offline)
        model.load(FixtureDisc(), bsdName: nil)
        await wait(until: { model.lookupState == .offline })
        check("with no network the window opens with Track NN titles", model.lookupState == .offline && model.rows[0].title == "Track 01")
        model.setAlbumTitle("Typed Album")
        model.setAlbumArtist("Typed Artist")
        model.setTitle("Typed Song", row: model.rows[0].id)
        check("typed details flow into the ripper", model.albumTitle == "Typed Album" && model.rows[0].title == "Typed Song")
        model.rip()
        await wait(until: { !model.isRipping })
        let typed = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "Typed Artist/Typed Album").path)) ?? []).sorted()
        check("typed details name the files and folders", typed == ["01 - Typed Song.mp3", "02 - Track 02.mp3", "03 - Track 03.mp3"], "\(typed)")

        // S-015: a set of discs gets a Disc folder, and a compilation names files by artist.
        model.eject()
        model.lookup = FixtureLookup(mode: .found)
        model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
        await wait(until: { model.lookupState == .found })
        model.chooseMatch(id: "fixture-2")
        model.rip()
        await wait(until: { !model.isRipping })
        let disc2 = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "The Tones/Sine Waves (Deluxe Edition)/Disc 2").path)) ?? []).sorted()
        check("a two-disc set rips into a Disc 2 folder", disc2 == ["01 - Low A (Live).mp3", "02 - Rising Fifth (Live).mp3"], "\(disc2)")

        model.eject()
        model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
        await wait(until: { model.lookupState == .found })
        model.setAlbumArtist("Various Artists")
        model.setAlbumTitle("Mix")
        model.rip()
        await wait(until: { !model.isRipping })
        let mix = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "Various Artists/Mix").path)) ?? []).sorted()
        check("a compilation puts the artist in each file name", mix == ["01 - The Tones - Low A.mp3", "02 - The Tones - Rising Fifth.mp3"], "\(mix)")
        model.eject()
    }

    private static func wait(until done: () -> Bool, seconds: Double = 20) async {
        let end = Date.now.addingTimeInterval(seconds)
        while !done(), Date.now < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
