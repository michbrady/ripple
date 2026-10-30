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
            model.showSnapshot(.empty)
            check("no disc shows the empty state", model.phase == .empty && !model.hasDisc)

            // S-003: a disc shows one row per track, titled "Track NN".
            model.load(FixtureDisc(), bsdName: nil)
            check("a disc shows its tracks", model.phase == .ready && model.rows.count == 3)
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
            model.rows[0].title = "Intro / Overture"
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
            model.albumTitle = "Cancelled"
            model.rip()
            await wait(until: { if case .ripping(let f) = model.rows[1].status { f > 0.1 } else { false } })
            model.cancel()
            await wait(until: { !model.isRipping })
            let cancelled = ((try? fm.contentsOfDirectory(atPath: out.appending(path: "Unknown Artist/Cancelled").path)) ?? []).sorted()
            check("Cancel keeps finished tracks and removes the partial file", cancelled == ["01 - Track 01.mp3"], "\(cancelled)")
            check("Cancel returns to the track list", model.phase == .ready)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
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
