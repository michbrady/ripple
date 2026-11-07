import AppKit
import AVFoundation
import Foundation
import ImageIO
import RippleKit
import UniformTypeIdentifiers

@MainActor
extension SelfTest {
    /// S-026 to S-033: burn mode, on real MP3 files and a stand-in burner.
    static func burnChecks(burn: BurnModel, out: URL) async {
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

    /// Burns a small MP3 Disc on the real drive, then reads it back. This USES UP the blank disc, so it runs only
    /// when RIPPLE_REAL_BURN is set to the exact phrase below.
    static func realBurnCheck(out: URL) async {
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

    /// S-034: after a drag install, offer to eject the open installer and trash the .dmg. Real disk images, a real eject,
    /// and a real move to the Trash; only the answer to the question is faked.
    static func installerChecks(out: URL) async {
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

    /// The links the app opens must be secure web addresses on the right site, and the privacy page must sit beside the main page.
    static func linkChecks() {
        check("the website link is a secure address on bradysbit.com",
              AppLinks.website.absoluteString == "https://www.bradysbit.com/ripple/")   // URL.path drops the trailing slash, so compare the whole address
        check("the privacy page is a secure address beside the website",
              AppLinks.privacy.absoluteString == AppLinks.website.absoluteString + "privacy.html")
        check("the tip link is the Ko-fi page", AppLinks.tip.absoluteString == "https://ko-fi.com/bradysbit")
    }

    /// LAME must be a separate, replaceable library inside the app (it is LGPL), not code inside the program.
    /// Checked only when running from a real app bundle, where the library lives.
    static func libraryChecks() {
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
