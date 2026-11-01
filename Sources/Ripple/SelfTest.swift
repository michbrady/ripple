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
        // A real music CD in the drive: only the read-only real-disc checks run, and the disc is never written.
        if ProcessInfo.processInfo.environment["RIPPLE_REAL_CD"] == "1" {
            Task {
                await realCDChecks(model: model)
                print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
                finish(code: failures == 0 ? 0 : 1)
            }
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
            await looseMatchChecks(model: model)
            await formatChecks(model: model, out: out)
            await tagChecks(model: model, out: out)
            await attentionChecks(model: model, out: out)
            await burnChecks(burn: burn, out: out)
            await polishChecks(model: model, out: out)
            await installerChecks(out: out)
            realDriveChecks()
            libraryChecks()
            linkChecks()
            await realBurnCheck(out: out)
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
        check("an Audio CD does not go on a DVD", !burn.canBurn && burn.fitMessage == "An Audio CD needs a blank CD-R. This disc is a DVD-R.", "\(burn.fitMessage ?? "nil")")
        burn.type = .data
        check("an MP3 Disc does go on a DVD", burn.canBurn)
        burn.type = .audio

        // A CD-RW is allowed, with a heads-up: many older players cannot read one.
        let rewritable = BurnDeviceState.ready(BurnMedia(kind: .cd, label: "CD-RW", blocksFree: 359_847))
        burner.set(rewritable)
        await wait(until: { burn.deviceState == rewritable })
        check("an Audio CD on a CD-RW can burn, with a note about older players", burn.canBurn && burn.compatibilityNote?.contains("CD-R plays in more players") == true, "\(burn.compatibilityNote ?? "nil")")
        burn.type = .data
        check("an MP3 Disc on a CD-RW needs no such note", burn.compatibilityNote == nil)
        burn.type = .audio
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.deviceState == FixtureBurner.blankCD() })
        check("a blank CD-R needs no such note", burn.compatibilityNote == nil)

        // S-030: the drive and the disc.
        for (state, words) in [(BurnDeviceState.noDrive, "Connect a USB burner"), (.noDisc, "Insert a blank CD-R."),
                               (.notBlank(label: "CD-RW", rewritable: true), "Erase it in Disk Utility"),
                               (.notBlank(label: "CD-R", rewritable: false), "Insert a blank disc.")] {
            burner.set(state)
            await wait(until: { burn.deviceState == state })
            check("the drive line for \(state) says what to do", burn.deviceLine.contains(words) && !burn.canBurn, burn.deviceLine)
        }

        // S-031: burn an Audio CD. The files go to the burner in list order.
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.canBurn })
        burn.burn()
        check("Burn starts burning", burn.isBurning)
        await wait(until: { burn.phase == .done })
        check("the burn finishes", burn.phase == .done)
        let job = burner.jobs.last
        check("an Audio CD job carries the files in list order", job?.type == .audio && job?.files == burn.items.map(\.url))
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

        // S-036, S-037, S-038: M4A files, conversion to MP3, and folders on an MP3 Disc.
        let m4aSource = out.appending(path: "burn-m4a", directoryHint: .isDirectory)
        var m4aRequest = request
        m4aRequest.folder = m4aSource
        m4aRequest.format = .m4a
        m4aRequest.album = "Tunes"
        _ = try? await Ripper.rip(m4aRequest, onEvent: { _ in })
        let m4aFolder = m4aSource.appending(path: "The Tones/Tunes", directoryHint: .isDirectory)
        burn.clear()
        burn.load(folder: m4aFolder)
        await wait(until: { !burn.isScanning && !burn.items.isEmpty })
        check("a folder of M4A files is listed", burn.items.count == 3 && burn.items.allSatisfy { !$0.isMP3 }, "\(burn.items.count)")
        check("an M4A shows its title and artist", burn.items.map(\.title) == ["One", "Two", "Three"] && burn.items.allSatisfy { $0.artist == "The Tones" }, "\(burn.items.map(\.title))")
        burn.type = .audio
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.deviceState == FixtureBurner.blankCD() })
        check("an Audio CD takes M4A files", burn.conversionNote == nil && burn.fit == .fits)
        burn.type = .data
        check("an MP3 Disc says M4A files are converted", burn.conversionNote == "3 M4A files are converted to MP3 when the disc is burned.", "\(burn.conversionNote ?? "nil")")
        await burn.add(dropped: [folder.appending(path: "01 - One.mp3")])
        check("MP3 and M4A files mix in one list", burn.items.count == 4 && burn.conversionNote?.hasPrefix("3 M4A") == true, "\(burn.items.count)")
        // The real conversion: every M4A becomes a real MP3 in a work folder, then the work folder goes away.
        let entries = DiscLayout.entries(for: BurnJob(type: .data, files: burn.items.map(\.url), volumeName: "Mix"))
        if let prepared = try? await DiscPreparer.prepare(entries), let work = prepared.workFolder {
            let converted = prepared.entries.filter { $0.source.deletingLastPathComponent() == work }
            var readable = 0
            for entry in converted { if await BurnScanner.read(entry.source) != nil { readable += 1 } }
            check("M4A files are converted to MP3 files that play", converted.count == 3 && readable == 3 && converted.allSatisfy { $0.source.pathExtension == "mp3" })
            check("converted files are named like MP3 files", prepared.entries.map(\.name).allSatisfy { $0.hasSuffix(".mp3") }, "\(prepared.entries.map(\.name))")
            try? fm.removeItem(at: work)
        } else {
            check("M4A files are converted to MP3 files that play", false)
        }

        // Folders: make one, put a file in it, rename it, and the burn job carries the layout.
        burn.clear()
        burn.load(folder: folder)
        await wait(until: { !burn.isScanning && !burn.items.isEmpty })
        burn.type = .data
        burn.undoManager = nil
        check("a flat list shows no folders", !burn.showsFolders)
        let rock = burn.makeFolder(named: "Rock")
        check("a new folder appears, empty", rock == "Rock" && burn.folderPaths == ["Rock"] && burn.showsFolders && burn.items(in: "Rock").isEmpty)
        check("a second folder with the same name gets a number", burn.makeFolder(named: "Rock") == "Rock (2)")
        burn.removeFolder("Rock (2)")
        let one = burn.items[0].id
        let two = burn.items[1].id
        burn.move(ids: [one, two], toFolder: "Rock")
        check("files move into a folder", burn.items(in: "Rock").count == 2 && burn.items(in: "").count == 1)
        let live = burn.makeFolder(named: "Live", in: "Rock")
        burn.move(ids: [two], toFolder: live)
        check("a folder can sit inside a folder", live == "Rock/Live" && burn.folderPaths == ["Rock", "Rock/Live"])
        burn.renameFolder("Rock", to: "Rock Hits")
        check("renaming a folder keeps its files and subfolders", burn.items(in: "Rock Hits").count == 1 && burn.items(in: "Rock Hits/Live").count == 1, "\(burn.folderPaths)")
        let folderUndo = UndoManager()
        folderUndo.groupsByEvent = false
        burn.undoManager = folderUndo
        folderUndo.beginUndoGrouping()
        burn.move(ids: [two], toFolder: "")
        folderUndo.endUndoGrouping()
        folderUndo.undo()
        check("Undo puts a moved file back in its folder", burn.items(in: "Rock Hits/Live").count == 1)
        burn.undoManager = nil
        burn.nudge(id: burn.items(in: "")[0].id, by: -1)
        burner.set(FixtureBurner.blankDVD())
        await wait(until: { burn.canBurn })
        burn.burn()
        await wait(until: { burn.phase == .done })
        let layoutJob = burner.jobs.last
        check("the MP3 Disc job carries each file's folder", layoutJob?.placements == burn.items.map(\.folder) && layoutJob?.folders == ["Rock Hits", "Rock Hits/Live"], "\(layoutJob?.placements ?? []) \(layoutJob?.folders ?? [])")
        burn.tryAgain()
        burn.removeFolder("Rock Hits")
        check("removing a folder keeps its files, one level up", burn.items.count == 3 && burn.items(in: "Live").count == 1 && burn.items(in: "").count == 2, "\(burn.items.map(\.folder))")
        burn.type = .audio
        let audioBefore = burner.jobs.count
        burner.set(FixtureBurner.blankCD())
        await wait(until: { burn.canBurn })
        burn.burn()
        await wait(until: { burn.phase == .done })
        check("an Audio CD job has no folders", burner.jobs.count == audioBefore + 1 && burner.jobs.last?.placements.isEmpty == true && burner.jobs.last?.folders.isEmpty == true)
        burn.tryAgain()
        burn.clear()
        burn.load(folder: folder)
        await wait(until: { !burn.isScanning && !burn.items.isEmpty })
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

    /// S-034: after a drag install, offer to eject the open installer and trash the .dmg. Real disk images, a real eject,
    /// and a real move to the Trash; only the answer to the question is faked.
    private static func installerChecks(out: URL) async {
        let fm = FileManager.default
        func run(_ args: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        // A copy of this very app, packed into a disk image the way the installer is.
        let source = out.appending(path: "installer-src", directoryHint: .isDirectory)
        try? fm.createDirectory(at: source, withIntermediateDirectories: true)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [Bundle.main.bundleURL.path, source.appending(path: "Ripple.app").path]
        try? copy.run()
        copy.waitUntilExit()
        let downloads = out.appending(path: "fake-downloads", directoryHint: .isDirectory)
        try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        func makeAndMount(_ name: String, volume: String) -> (dmg: URL, mount: URL)? {
            let dmg = downloads.appending(path: name)
            guard run(["create", "-srcfolder", source.path, "-volname", volume, "-format", "UDZO", "-ov", dmg.path]),
                  run(["attach", dmg.path, "-readonly", "-nobrowse", "-noautoopen", "-quiet"]) else { return nil }
            return (dmg, URL(fileURLWithPath: "/Volumes/\(volume)", isDirectory: true))
        }
        let installed = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Ripple.app")

        guard let first = makeAndMount("Ripple.dmg", volume: "RippleInstallTestA") else {
            check("a test installer disk image can be made and opened", false)
            return
        }
        var asked = 0
        var answer = false
        var cleanup = InstallerCleanup()
        cleanup.ask = { _ in asked += 1; return answer }
        // The test sees only its own disk images, never one you opened yourself.
        let mine = downloads.resolvingSymlinksInPath().path
        cleanup.images = {
            InstallerCleanup.runningImages().filter {
                $0.imagePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(mine) } ?? false
            }
        }

        check("running from outside Applications offers nothing", await cleanup.offer(installedAt: URL(fileURLWithPath: "/tmp/Ripple.app")) == .notInstalled
              && asked == 0 && fm.fileExists(atPath: first.mount.path))
        check("an open installer is found when Ripple is installed, and the user is asked", await { () -> Bool in
            answer = false
            let outcome = await cleanup.offer(installedAt: installed)
            return outcome == .declined && asked == 1
        }())
        check("Keep leaves the disk image open and the file in place", fm.fileExists(atPath: first.mount.path) && fm.fileExists(atPath: first.dmg.path))
        check("after Keep, the same installer is not asked about again", await { () -> Bool in
            answer = true
            let outcome = await cleanup.offer(installedAt: installed)
            return outcome == .declined && asked == 1
        }())

        // A different installer file: this time the answer is yes.
        _ = run(["detach", first.mount.path, "-force", "-quiet"])
        guard let second = makeAndMount("Ripple 2.dmg", volume: "RippleInstallTestB") else {
            check("a second test installer can be opened", false)
            return
        }
        answer = true
        let outcome = await cleanup.offer(installedAt: installed)
        var trashedAt: URL?
        if case .trashed(let url) = outcome { trashedAt = url }
        check("Move to Trash ejects the disk image", outcome != .declined && !fm.fileExists(atPath: second.mount.path), "\(outcome)")
        check("Move to Trash takes the .dmg out of its folder", !fm.fileExists(atPath: second.dmg.path))
        check("the .dmg is in the Trash", trashedAt.map { fm.fileExists(atPath: $0.path) } == true, "\(trashedAt?.path ?? "nil")")
        if let trashedAt { try? fm.removeItem(at: trashedAt) }

        check("with no installer open, nothing is offered", await cleanup.offer(installedAt: installed) == .nothingToClean)
        check("only Applications and ~/Applications count as installed",
              InstallerCleanup.isInstalledLocation(URL(fileURLWithPath: "/Applications/Ripple.app"))
              && InstallerCleanup.isInstalledLocation(installed)
              && !InstallerCleanup.isInstalledLocation(URL(fileURLWithPath: "/Volumes/Ripple/Ripple.app"))
              && !InstallerCleanup.isInstalledLocation(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/Ripple.app")))
        try? fm.removeItem(at: first.dmg)
    }

    /// S-022 to S-024: eject when done, start on a match, and clear messages.
    private static func polishChecks(model: AppModel, out: URL) async {
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

    /// Burns a small MP3 Disc on the real drive, then reads it back. This USES UP the blank disc, so it runs only
    /// when RIPPLE_REAL_BURN is set to the exact phrase below.
    private static func realBurnCheck(out: URL) async {
        guard ProcessInfo.processInfo.environment["RIPPLE_REAL_BURN"] == "I_UNDERSTAND_THIS_USES_UP_THE_DISC" else { return }
        let fm = FileManager.default
        let real = DiscRecordingBurner(completion: .mount)
        guard case .ready(let media) = real.state() else {
            check("a blank disc is in the real drive", false, "\(real.state())")
            return
        }
        print("INFO real burn: \(real.deviceName ?? "?"), blank \(media.label), \(media.blocksFree) blocks free")

        // Three tagged MP3 files, eight seconds each, found the way the app finds them.
        let source = out.appending(path: "real-burn-source", directoryHint: .isDirectory)
        let request = RipRequest(disc: FixtureDisc(trackSeconds: [8, 8, 8]),
                                 tracks: ["One", "Two", "Three"].enumerated().map { RipTrack(number: $0.offset + 1, title: $0.element, artist: "The Tones") },
                                 albumArtist: "The Tones", album: "Real Burn Test", folder: source, quality: .vbr(4), verify: false)
        _ = try? await Ripper.rip(request, onEvent: { _ in })
        let scan = await BurnScanner.scan(source)
        check("three MP3 files are ready to burn", scan.items.map(\.title) == ["One", "Two", "Three"], "\(scan.items.map(\.title))")
        let job = BurnJob(type: .data, files: scan.items.map(\.url), volumeName: "RIPPLE TEST")

        let lastPrinted = ProgressMemory()
        do {
            try await real.burn(job) { stage in
                switch stage {
                case .preparing: print("INFO stage: preparing")
                case .finishing: print("INFO stage: finishing")
                case .burning(let fraction):
                    let step = (fraction * 10).rounded(.down) / 10
                    if lastPrinted.changed(to: step) { print("INFO stage: burning \(Int(step * 100))%") }
                }
            }
            check("the real burn finishes without an error", true)
        } catch {
            check("the real burn finishes without an error", false, "\(error)")
            return
        }

        // Read the disc back: it should mount, and every file should match its source byte for byte.
        let volume = URL(fileURLWithPath: "/Volumes/RIPPLE TEST", isDirectory: true)
        await wait(until: { fm.fileExists(atPath: volume.path) }, seconds: 90)
        check("the disc mounts as RIPPLE TEST", fm.fileExists(atPath: volume.path))
        // The volume appears before its files can be listed. Wait for them.
        await wait(until: { ((try? fm.contentsOfDirectory(atPath: volume.path)) ?? []).count >= 3 }, seconds: 60)
        let onDisc = ((try? fm.contentsOfDirectory(atPath: volume.path)) ?? []).sorted()
        print("INFO on the disc: \(onDisc)")
        let wanted = ["01 - One.mp3", "02 - Two.mp3", "03 - Three.mp3"]
        check("the disc holds the files as numbered names, in list order", onDisc == wanted, "\(onDisc)")
        for (item, name) in zip(scan.items, wanted) {
            let original = try? Data(contentsOf: item.url)
            let copy = try? Data(contentsOf: volume.appending(path: name))
            check("\(name) on the disc is identical to its source", original != nil && original == copy, "\(original?.count ?? -1) vs \(copy?.count ?? -1) bytes")
        }
        if let first = onDisc.first, let item = await BurnScanner.read(volume.appending(path: first)) {
            check("a file read back from the disc is a valid MP3 with its tags", item.title == "One" && abs(item.seconds - 8) < 0.3, "\(item.title) \(item.seconds)")
        }
    }

    /// S-002 to S-004 on a real music CD. Read-only.
    private static func realCDChecks(model: AppModel) async {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appending(path: "ripple-realcd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: out) }
        model.outputFolder = out

        // S-002: the app notices the disc and shows its tracks by itself.
        await wait(until: { model.hasDisc && model.phase == .ready }, seconds: 30)
        check("the app detects the inserted disc and shows its tracks", model.hasDisc && model.phase == .ready, "\(model.phase)")
        guard let disc = model.disc else { return }
        let toc = disc.toc
        print("INFO tracks on screen: \(model.rows.count), TOC entries: \(toc.entries.count), audio: \(toc.audioTracks.count), lead-out: \(toc.leadOut)")
        print("INFO first entries: \(toc.entries.prefix(3).map { "#\($0.number)@\($0.lba)\($0.isAudio ? "" : " DATA")" })")
        print("INFO last entries: \(toc.entries.suffix(3).map { "#\($0.number)@\($0.lba)\($0.isAudio ? "" : " DATA")" })")
        print("INFO MusicBrainz disc ID: \(toc.discID)")
        print("INFO MusicBrainz toc: \(toc.musicBrainzTOC.prefix(80))...")

        // S-003: the table of contents.
        check("the track list has one row per audio track", model.rows.count == toc.audioTracks.count && !model.rows.isEmpty)
        check("every track has a plausible length", model.rows.allSatisfy { $0.seconds > 1 && $0.seconds < 3_600 })
        let total = toc.audioTracks.indices.reduce(0.0) { $0 + toc.seconds(ofTrack: $1) }
        print("INFO total audio time: \(Int(total / 60)) min \(Int(total) % 60) s")

        // The lookup runs against the real MusicBrainz.
        await wait(until: { model.lookupState != .searching && model.lookupState != .idle }, seconds: 30)
        print("INFO lookup: \(model.lookupState), matches: \(model.matches.count), album: \(model.albumTitle) / \(model.albumArtist)")

        // S-004: raw reads. Compare with the system's own copy of the audio (the .aiff files the CD filesystem shows).
        // macOS names the volume after the disc ("Audio CD", or the album once it is identified): find it by its .aiff files.
        let volume = ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { URL(fileURLWithPath: "/Volumes/\($0)", isDirectory: true) }
            .first { ((try? fm.contentsOfDirectory(atPath: $0.path)) ?? []).contains { $0.hasSuffix(".aiff") } }
            ?? URL(fileURLWithPath: "/Volumes/Audio CD", isDirectory: true)
        print("INFO the system's copy of the audio is at: \(volume.lastPathComponent)")
        let aiffs = ((try? fm.contentsOfDirectory(atPath: volume.path)) ?? []).filter { $0.hasSuffix(".aiff") }
        let first = aiffs.first { $0.hasPrefix("1 ") }
        let range = toc.sectors(ofTrack: 0)
        let probe = 300
        let a = try? disc.readSectors(start: range.lowerBound + 1_000, count: probe)
        let b = try? disc.readSectors(start: range.lowerBound + 1_000, count: probe)
        check("a raw read returns exactly sectors times 2352 bytes", a?.count == probe * 2_352, "\(a?.count ?? -1)")
        check("reading the same sectors twice gives the same bytes", a != nil && a == b)
        if let first, let a, let pcm = aiffPCM(volume.appending(path: first)) {
            let offset = 1_000 * 2_352
            let swapped = Data(pcm[pcm.startIndex + offset ..< min(pcm.endIndex, pcm.startIndex + offset + probe * 2_352)])
            check("raw audio matches the system's copy of track 1, byte for byte", swapped == a, "\(swapped.count) vs \(a.count) bytes")
            // Stress: many reads from scattered places, each compared to the system's copy.
            var trials = 0, badTrials = 0, badSectors = 0
            var firstBad: [String] = []
            var generator = SystemRandomNumberGenerator()
            let usable = range.count - 330
            for _ in 0..<40 {
                let startSector = Int.random(in: 0..<usable, using: &generator)
                guard let read = try? disc.readSectors(start: range.lowerBound + startSector, count: 300) else { continue }
                trials += 1
                var bad: [Int] = []
                for index in 0..<300 {
                    let theirs = pcm[pcm.startIndex + (startSector + index) * 2_352 ..< pcm.startIndex + (startSector + index + 1) * 2_352]
                    if Data(theirs) != read[index * 2_352 ..< (index + 1) * 2_352] { bad.append(index) }
                }
                if !bad.isEmpty {
                    badTrials += 1
                    badSectors += bad.count
                    if firstBad.count < 6 { firstBad.append("start \(startSector): \(bad.count) bad at read positions \(bad.prefix(5))..\(bad.last ?? 0)") }
                }
            }
            print("INFO stress: \(trials) reads of 300 sectors from random places; \(badTrials) had differences, \(badSectors) sectors differ in all")
            for line in firstBad { print("INFO   \(line)") }
            check("40 scattered raw reads all match the system's copy", trials > 0 && badTrials == 0, "\(badTrials) of \(trials) reads differed")
            // Which sectors differ, for reads that start at different places?
            for startSector in [980, 1_000, 1_010, 1_017, 1_018, 1_500, 5_000, 7_700] {
                guard let read = try? disc.readSectors(start: range.lowerBound + startSector, count: 100) else { continue }
                var bad: [Int] = []
                for index in 0..<100 {
                    let theirs = pcm[pcm.startIndex + (startSector + index) * 2_352 ..< pcm.startIndex + (startSector + index + 1) * 2_352]
                    if Data(theirs) != read[index * 2_352 ..< (index + 1) * 2_352] { bad.append(index) }
                }
                let shown = bad.count > 24 ? "\(bad.prefix(24)) ..." : "\(bad)"
                print("INFO read of 100 sectors from track sector \(startSector): \(bad.count) differ, at read positions \(shown)")
            }
            if swapped != a {
                let first = zip(swapped, a).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                let differing = zip(swapped, a).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                print("INFO first differing byte: \(first) of \(a.count); differing bytes: \(differing)")
                // Is it the same audio, shifted by some frames (4 bytes each)?
                let window = 20_000
                let middle = a.count / 2
                let target = Data(a[middle ..< middle + window])
                var found: Int?
                for shift in -6_000...6_000 {
                    let start = middle + shift * 4
                    if start >= 0, start + window <= swapped.count, Data(swapped[swapped.startIndex + start ..< swapped.startIndex + start + window]) == target { found = shift; break }
                }
                print("INFO the raw read matches the system copy when shifted by: \(found.map { "\($0) frames" } ?? "no shift in +-6000 frames")")
            }
        } else {
            check("the system's copy of track 1 could be read for comparison", false, "files: \(aiffs.prefix(3))")
        }
        let started = Date.now
        let sample = try? disc.readSectors(start: range.lowerBound, count: 26 * 40)
        let seconds = Date.now.timeIntervalSince(started)
        print("INFO read speed: \(Int(Double(26 * 40) / max(seconds, 0.001))) sectors/s (\(String(format: "%.1f", Double(26 * 40) / 75 / max(seconds, 0.001)))x)")
        check("a longer raw read succeeds", sample?.count == 26 * 40 * 2_352)

        if ProcessInfo.processInfo.environment["RIPPLE_REAL_CD_TIMING"] == "1" {
            // How long does track 1 (105 s of audio) take to rip, by chunk size and Check for Errors?
            let tracks = model.rows.map { RipTrack(number: $0.number, title: $0.title, include: $0.id == 0) }
            for (verify, chunk) in [(false, 26), (false, 150), (true, 26), (true, 150), (true, 300)] {
                let folder = out.appending(path: "timing-\(verify)-\(chunk)", directoryHint: .isDirectory)
                let request = RipRequest(disc: disc, tracks: tracks, albumArtist: "T", album: "T", folder: folder,
                                         quality: .vbr(2), verify: verify, chunkSectors: chunk)
                let began = Date.now
                _ = try? await Ripper.rip(request, onEvent: { _ in })
                let took = Date.now.timeIntervalSince(began)
                print("INFO timing: check for errors \(verify ? "on " : "off"), \(chunk) sectors per read: \(String(format: "%5.1f", took)) s for \(Int(model.rows[0].seconds)) s of audio = \(String(format: "%.1f", model.rows[0].seconds / took))x real time")
            }
            return
        }
        if ProcessInfo.processInfo.environment["RIPPLE_REAL_CD_SKIP_RIP"] == "1" { return }
        // A real rip of one track, with Check for Errors on.
        for index in model.rows.indices { model.rows[index].include = index < 1 }
        model.verifyReads = true
        model.format = .mp3
        let ripStart = Date.now
        model.rip()
        await wait(until: { !model.isRipping }, seconds: 300)
        print("INFO real rip of 1 track took \(String(format: "%.1f", Date.now.timeIntervalSince(ripStart))) s")
        let files = ((try? fm.enumerator(at: out, includingPropertiesForKeys: nil))?.compactMap { $0 as? URL }.filter { $0.pathExtension == "mp3" } ?? []).sorted { $0.path < $1.path }
        check("a real rip makes one MP3 per checked track", files.count == 1, "\(files.map(\.lastPathComponent))")
        check("a real rip finishes with no track needing attention", model.needsAttentionCount == 0, "\(model.rows.prefix(1).map(\.status))")
        for (file, row) in zip(files, model.rows.prefix(1)) {
            let item = await BurnScanner.read(file)
            print("INFO \(file.lastPathComponent): \(String(format: "%.2f", item?.seconds ?? 0)) s, TOC says \(String(format: "%.2f", row.seconds)) s")
            check("\(file.lastPathComponent) is as long as the disc says", item != nil && abs((item?.seconds ?? 0) - row.seconds) < 0.2)
        }
    }

    /// The PCM of an AIFF or AIFC file, as little-endian 16-bit samples like the raw disc reads. The CD filesystem's
    /// files are AIFC with compression type "sowt", which is already little-endian.
    private static func aiffPCM(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        var position = 12
        var littleEndian = false
        while position + 8 <= data.count {
            let id = String(decoding: data[position ..< position + 4], as: UTF8.self)
            let size = data[position + 4 ..< position + 8].reduce(0) { $0 << 8 | Int($1) }
            if id == "COMM", size >= 22 {
                littleEndian = String(decoding: data[position + 8 + 18 ..< position + 8 + 22], as: UTF8.self) == "sowt"
            }
            if id == "SSND" {
                let skip = data[position + 8 ..< position + 12].reduce(0) { $0 << 8 | Int($1) }
                let start = position + 16 + skip
                let pcm = Data(data[start ..< min(data.count, position + 8 + size)])
                if littleEndian { return pcm }
                var swapped = Data(capacity: pcm.count)
                var index = 0
                while index + 1 < pcm.count { swapped.append(pcm[index + 1]); swapped.append(pcm[index]); index += 2 }
                return swapped
            }
            position += 8 + size + (size % 2)
        }
        return nil
    }

    /// The links the app opens must be secure web addresses on the right site, and the privacy page must sit beside the main page.
    private static func linkChecks() {
        check("the website link is a secure address on bradysbit.com",
              AppLinks.website.absoluteString == "https://www.bradysbit.com/ripple/")   // URL.path drops the trailing slash, so compare the whole address
        check("the privacy page is a secure address beside the website",
              AppLinks.privacy.absoluteString == AppLinks.website.absoluteString + "privacy.html")
        check("the tip link is the Ko-fi page", AppLinks.tip.absoluteString == "https://ko-fi.com/bradysbit")
    }

    /// LAME must be a separate, replaceable library inside the app (it is LGPL), not code inside the program.
    /// Checked only when running from a real app bundle, where the library lives.
    private static func libraryChecks() {
        let fm = FileManager.default
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        func tool(_ path: String, _ args: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let library = Bundle.main.bundleURL.appending(path: "Contents/Frameworks/libmp3lame.0.dylib")
        let program = Bundle.main.executableURL?.path ?? ""
        check("LAME is a separate library file inside the app", fm.fileExists(atPath: library.path))
        check("the program links LAME by name, not by copying it in",
              tool("/usr/bin/otool", ["-L", program]).contains("@rpath/libmp3lame.0.dylib"))
        check("the program holds none of LAME's own code",
              !tool("/usr/bin/nm", ["-gU", program]).contains(" T _lame_init"))
        check("the library holds LAME's encoder and no decoder",
              tool("/usr/bin/nm", ["-gU", library.path]).contains(" T _lame_init")
              && !tool("/usr/bin/nm", ["-gU", library.path]).lowercased().contains("hip_decode"))
        let notices = Bundle.main.bundleURL.appending(path: "Contents/Resources/Licenses")
        check("the LGPL licence and the source notice travel inside the app",
              fm.fileExists(atPath: notices.appending(path: "LICENSE-LAME.txt").path)
              && fm.fileExists(atPath: notices.appending(path: "LAME-NOTICE.txt").path))
        check("the finished program carries no path from the developer's Mac",
              !tool("/usr/bin/otool", ["-l", program]).contains("/Documents/GitHub"))
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
            // Three one-second tracks (75 sectors each). Without checking, reads are 26 sectors: 3 reads a track, 9 in all.
            // With checking, reads are 300 sectors: each track is one read, done twice, so at least 6.
            let reads = faults.reads
            check(verify ? "Check for Errors reads every track at least twice" : "without Check for Errors each part is read once",
                  verify ? reads >= 6 : reads == 9, "\(reads) reads")
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

    /// A disc MusicBrainz has no exact record of: only a match whose track lengths fit is filled in.
    private static func looseMatchChecks(model: AppModel) async {
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

/// Remembers the last progress step printed, so the log shows one line per 10 percent.
private nonisolated final class ProgressMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func changed(to value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { last = value }
        return last != value
    }
}
