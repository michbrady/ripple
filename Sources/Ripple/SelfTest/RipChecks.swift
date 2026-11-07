import AppKit
import AVFoundation
import Foundation
import ImageIO
import RippleKit
import UniformTypeIdentifiers

@MainActor
extension SelfTest {
    /// S-010 to S-015: the album lookup, matches, edits, cover, multi-disc, compilations.
    static func lookupChecks(model: AppModel, out: URL) async {
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

    /// A disc MusicBrainz has no exact record of: only a match whose track lengths fit is filled in.
    static func looseMatchChecks(model: AppModel) async {
        model.eject()
        model.lookup = FixtureLookup(mode: .guesses)
        model.load(FixtureDisc(), bsdName: nil)
        await wait(until: { model.lookupState == .possible })
        check("poor guesses fill in nothing", model.lookupState == .possible && model.albumTitle.isEmpty && model.albumArtist.isEmpty
              && model.rows.map(\.title) == ["Track 01", "Track 02", "Track 03"] && model.matchConfidence == nil)
        check("the guesses are still offered to choose from", model.matches.count == 2 && model.matches.allSatisfy { $0.confidence == .guess })
        model.chooseMatch(id: "guess-1")
        check("choosing a guess fills it in", model.albumTitle == "Sine Wave Soundtrack" && model.matchConfidence == .guess)

        model.eject()
        model.lookup = FixtureLookup(mode: .loose)
        model.load(FixtureDisc(), bsdName: nil)
        await wait(until: { model.lookupState == .found })
        check("a loose match whose track lengths fit is filled in", model.albumTitle == "Sine Waves" && model.matches.count == 3)
        check("it is marked as not an exact disc match", model.matchConfidence == .byLength)
        model.eject()
    }

    /// S-007, S-016 to S-018: Output Folder, format, and quality are saved and used.
    static func formatChecks(model: AppModel, out: URL) async {
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
        check("a fresh install ejects when done and does not start by itself", fresh.ejectWhenDone && !fresh.startOnMatch)
        fresh.ejectWhenDone = false
        fresh.startOnMatch = true
        let second = AppModel(defaults: defaults)
        check("Eject when done and Start when a disc matches survive a restart", !second.ejectWhenDone && second.startOnMatch)
        fresh.ejectWhenDone = true
        fresh.startOnMatch = false

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

    /// S-019: what the model shows ends up in the files.
    static func tagChecks(model: AppModel, out: URL) async {
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

    /// S-020, S-021: a scratched disc is saved, flagged, and can be ripped again.
    static func attentionChecks(model: AppModel, out: URL) async {
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
            // Three one-second tracks (75 sectors each). Without checking, reads are 26 sectors: 3 reads a track, 9 in all.
            // With checking, reads are 300 sectors: each track is one read, done twice, so at least 6.
            let reads = faults.reads
            check(verify ? "Check for Errors reads every track at least twice" : "without Check for Errors each part is read once",
                  verify ? reads >= 6 : reads == 9, "\(reads) reads")
        }
        model.verifyReads = true
        model.eject()
    }

    /// S-022 to S-024: eject when done, start on a match, and clear messages.
    static func polishChecks(model: AppModel, out: URL) async {
        let fm = FileManager.default
        model.lookup = FixtureLookup(mode: .none)
        model.startOnMatch = false
        model.verifyReads = true
        model.format = .mp3

        func fresh(_ title: String, tracks: [Double] = [1, 1], faults: FixtureDisc.Faults? = nil) {
            model.eject()
            model.load(FixtureDisc(trackSeconds: tracks, faults: faults), bsdName: nil)
            model.setAlbumArtist("Polish")
            model.setAlbumTitle(title)
        }
        func isDone() -> Bool { if case .done = model.phase { true } else { false } }

        // S-022: Eject when done.
        model.ejectWhenDone = true
        fresh("Clean")
        model.rip()
        await wait(until: { isDone() })
        check("a clean rip ejects the disc when Eject when done is on", model.isDiscEjected)
        check("the finished page stays up after the disc is ejected", isDone() && model.rows.count == 2 && model.rippedCount == 2)

        model.ejectWhenDone = false
        fresh("Stay")
        model.rip()
        await wait(until: { isDone() })
        check("with Eject when done off the disc stays in", !model.isDiscEjected)

        model.ejectWhenDone = true
        fresh("Scratched", tracks: [1, 1, 1], faults: .init(failFirst: [100: 8]))
        model.rip()
        await wait(until: { isDone() })
        check("a rip with tracks that need attention keeps the disc in", !model.isDiscEjected && model.needsAttentionCount == 1)
        model.retry(model.rows[1].id)
        await wait(until: { isDone() && !model.isRipping })
        check("the disc ejects once a Retry clears the last warning", model.isDiscEjected && model.needsAttentionCount == 0)

        // S-023: Start when a disc matches.
        model.ejectWhenDone = false
        model.startOnMatch = true
        model.lookup = FixtureLookup(mode: .single)
        model.eject()
        model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
        await wait(until: { isDone() })
        let started = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "The Tones/Sine Waves").path)) ?? []).sorted()
        check("one exact match starts ripping by itself", isDone() && started == ["01 - Low A.mp3", "02 - Rising Fifth.mp3"], "\(started)")

        for (mode, name) in [(FixtureLookup.Mode.found, "several matches"), (.none, "no match")] {
            model.lookup = FixtureLookup(mode: mode)
            model.eject()
            model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
            await wait(until: { model.lookupState == .found || model.lookupState == .notFound })
            try? await Task.sleep(for: .milliseconds(500))
            check("\(name) waits for the user", model.phase == .ready)
        }
        model.startOnMatch = false
        model.lookup = FixtureLookup(mode: .single)
        model.eject()
        model.load(FixtureDisc(trackSeconds: [1, 1]), bsdName: nil)
        await wait(until: { model.lookupState == .found })
        try? await Task.sleep(for: .milliseconds(500))
        check("with Start when a disc matches off, one exact match waits too", model.phase == .ready)

        // S-024: clear messages.
        model.lookup = FixtureLookup(mode: .none)
        model.eject()
        model.openDisc = { _ in throw DeviceDisc.OpenError.noTableOfContents }
        model.discInserted(bsdName: "disk99")
        await wait(until: { if case .failed = model.phase { true } else { false } })
        check("an unreadable disc says so, with one action",
              model.phase == .failed(RipFailure(message: "Ripple cannot read this disc.", action: .tryAgain)), "\(model.phase)")
        model.openDisc = { _ in FixtureDisc(trackSeconds: [1, 1]) }
        model.performFailureAction()
        await wait(until: { model.phase == .ready })
        check("Try Again reads the disc again", model.phase == .ready && model.rows.count == 2)

        let locked = out.appending(path: "Locked", directoryHint: .isDirectory)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let good = model.outputFolder
        model.outputFolder = locked
        model.rip()
        await wait(until: { if case .failed = model.phase { true } else { false } })
        var failure: RipFailure?
        if case .failed(let found) = model.phase { failure = found }
        check("an unwritable folder stops the rip with a message naming the folder",
              failure?.message == "Ripple cannot save to \u{201C}Locked\u{201D}. The folder is not writable. Choose another Output Folder." && failure?.action == .chooseFolder,
              failure?.message ?? "nil")
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        model.outputFolder = good
        model.resumeAfterFailure()
        check("choosing another folder returns to the track list with the disc still loaded", model.phase == .ready && model.rows.count == 2)
        model.rip()
        await wait(until: { isDone() })
        check("the rip works once the folder is fine", isDone())

        model.openDisc = { try DeviceDisc(bsdName: $0) }
        model.ejectWhenDone = true
        model.eject()
    }

    /// Covers are kept when they are small JPEG or PNG, and converted otherwise.
    static func coverPrepChecks() {
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
}
