import AppKit
import Foundation
import RippleKit

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

    static func runIfRequested(model: AppModel) {
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

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
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
