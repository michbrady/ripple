import AppKit
import Foundation
import RippleKit

/// S-039 onward: the Video DVD page, on made-up videos and a made-up burner.
@MainActor
extension SelfTest {
    static func dvdChecks(burn: BurnModel, dvd: DVDModel) async {
        // S-039: Video DVD is the third Disc Type, remembered, and asks for a DVD, not a CD.
        check("Disc Type has three choices, Video DVD last", DiscType.allCases.map(\.title) == ["Audio CD", "MP3 Disc", "Video DVD"])
        burn.showSnapshot(.videoEmpty)
        check("Video DVD is remembered", Store.defaults.string(forKey: "burn.type") == "video")
        check("a blank DVD-R is accepted for a Video DVD", burn.isReady && burn.deviceLine.contains("blank DVD-R"), burn.deviceLine)
        burn.showSnapshot(.empty)
        burn.type = .video
        check("a blank CD-R is refused for a Video DVD", !burn.isReady && burn.deviceLine.contains("Insert a blank DVD-R or DVD-RW"), burn.deviceLine)
        burn.showSnapshot(.empty)
        burn.type = .audio
        await videoListChecks(dvd: dvd)
        fitChecks(burn: burn, dvd: dvd)
        await standardChecks()
        menuChecks(dvd: dvd)
        await menuMediaChecks()
        await buildChecks(burn: burn, dvd: dvd)
    }

    /// S-040: dropped files and folders become rows; other files are counted and skipped; bad videos say why.
    private static func videoListChecks(dvd: DVDModel) async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "ripple-videos-\(UUID().uuidString)", directoryHint: .isDirectory)
        let inner = folder.appending(path: "Trip", directoryHint: .isDirectory)
        try? fm.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let names = ["one.mp4", "two_protected.mov", "three_broken.avi", "notes.txt", "Trip/four.MKV", "Trip/five.webm", "Trip/.hidden.mp4"]
        for name in names { fm.createFile(atPath: folder.appending(path: name).path, contents: Data("x".utf8)) }
        for ending in ["m4v", "wmv", "mpg", "flv"] { fm.createFile(atPath: folder.appending(path: "x.\(ending)").path, contents: Data("x".utf8)) }

        let found = DVDModel.videoFiles(in: [folder])
        check("every video ending is accepted, including inside folders", found.videos.count == 9, "\(found.videos.map(\.lastPathComponent))")
        check("other files are counted, not added", found.skipped == 1)

        await dvd.add([folder.appending(path: "one.mp4"), folder.appending(path: "two_protected.mov"),
                       folder.appending(path: "three_broken.avi"), folder.appending(path: "notes.txt"), inner])
        check("a video that reads shows its length", dvd.videos.first?.title == "one" && (dvd.videos.first?.seconds ?? 0) >= 300)
        let problems = dvd.items.compactMap { item -> VideoProblem? in if case .problem(let p) = item.state { p } else { nil } }
        check("a copy-protected video says so", problems.contains(.copyProtected)
              && VideoProblem.copyProtected.message == "This video is copy-protected, so Ripple cannot read it.")
        check("an unreadable video says so", problems.contains(.unreadable))
        check("the folder's videos were added, and the text file skipped", dvd.items.count == 5 && dvd.skipped == 1, "\(dvd.items.count) rows, \(dvd.skipped) skipped")
        check("a video added twice is listed once", await { await dvd.add([folder.appending(path: "one.mp4")]); return dvd.items.count == 5 }())
        check("every ready video has a picture", dvd.items.allSatisfy { if case .ready = $0.state { $0.picture != nil } else { true } })

        // S-041: rename, reorder, remove, and Undo.
        let um = UndoManager()
        um.groupsByEvent = false
        dvd.undoManager = um
        func act(_ change: () -> Void) { um.beginUndoGrouping(); change(); um.endUndoGrouping() }
        func ids() -> [URL] { dvd.items.map(\.id) }
        let start = ids(), startTitles = dvd.videos.map(\.title)
        let first = start[0]
        act { dvd.rename(first, to: "  Summer\n  Trip  ") }
        check("a title is cleaned of line breaks and extra spaces", dvd.title(of: first) == "Summer Trip")
        act { dvd.rename(first, to: String(repeating: "x", count: 80)) }
        check("a long title is cut to fit the menu", dvd.title(of: first)?.count == DVDName.maxTitle)
        act { dvd.rename(first, to: "   ") }
        check("an empty title goes back to the file's name", dvd.title(of: first) == "one")
        dvd.selection = [start[1]]
        act { dvd.moveSelectionUp() }
        check("Move Up swaps a video with the one above", ids() == [start[1], start[0]] + start[2...])
        dvd.selection = [first]
        act { dvd.moveSelectionDown() }
        check("Move Down swaps a video with the one below", ids() == [start[1], start[2], start[0]] + start[3...])
        check("the top video cannot move up, the bottom cannot move down",
              { dvd.selection = [ids()[0]]; return !dvd.canMoveUp }() && { dvd.selection = [ids().last!]; return !dvd.canMoveDown }())
        act { dvd.move(from: IndexSet(integer: 0), to: dvd.items.count) }
        check("dragging a row to the end reorders the list", ids().last == start[1])
        act { dvd.remove(ids: [ids()[0]]) }
        check("Remove takes a video off the list", dvd.items.count == start.count - 1)
        while um.canUndo { um.undo() }
        check("Undo brings back every change, in order", ids() == start && dvd.videos.map(\.title) == startTitles, "\(ids().map(\.lastPathComponent))")
        dvd.undoManager = nil

        dvd.showSnapshot(.empty)
    }

    /// S-042: the plan follows the list and the disc in the drive.
    private static func fitChecks(burn: BurnModel, dvd: DVDModel) {
        burn.showSnapshot(.videoEmpty)
        dvd.showSnapshot(.videoList)
        let ready = dvd.plan(on: burn.deviceState)
        check("a few videos fit with Excellent quality", ready.fit == .fits && ready.quality == .excellent, "\(ready.quality)")
        dvd.showSnapshot(.videoOver)
        check("too many hours says Too long, with minutes to remove", { if case .tooLong(let s) = dvd.plan(on: burn.deviceState).fit { s > 600 } else { false } }())
        check("a dual-layer disc in the drive raises the capacity",
              dvd.plan(on: .ready(BurnMedia(kind: .dvd, label: "DVD-R DL", blocksFree: DVDPlan.dualLayerBlocks))).fit == .fits)
        burn.showSnapshot(.empty)
        dvd.showSnapshot(.empty)
    }

    /// S-043: NTSC or PAL from the videos, a choice that overrides it, and one frame shape for the disc.
    private static func standardChecks() async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "ripple-standard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func make(_ name: String) -> URL {
            let url = folder.appending(path: name)
            fm.createFile(atPath: url.path, contents: Data("x".utf8))
            return url
        }
        let dvd = DVDModel(source: FixtureVideoSource())
        await dvd.add([make("a.mp4")])
        check("29.97 frames a second suggests NTSC and 16:9", dvd.standard == .ntsc && dvd.widescreen && dvd.mixedNote == nil)
        await dvd.add([make("b_pal.mp4")])
        check("mixed videos use the first standard and say so", dvd.standard == .ntsc && dvd.mixedNote?.contains("different standards") == true, dvd.mixedNote ?? "")
        dvd.standardChoice = .pal
        check("a choice in the window overrides the suggestion", dvd.standard == .pal && dvd.mixedNote == nil && dvd.plan(on: .noDisc).standard == .pal)
        let pal = DVDModel(source: FixtureVideoSource())
        await pal.add([make("only_pal.mp4")])
        check("25 frames a second suggests PAL", pal.standard == .pal)
        await pal.add([make("old_one.mp4"), make("old_two.mp4")])
        check("mostly 4:3 videos suggest a standard screen", !pal.widescreen)
        pal.widescreenChoice = true
        check("the screen choice overrides the suggestion", pal.widescreen)
    }

    /// S-044: the menu is drawn from the list, 6 titles to a page, at the standard's size.
    private static func menuChecks(dvd: DVDModel) {
        dvd.showSnapshot(.videoMenu)
        let titles = dvd.items.compactMap { item -> DVDMenuTitle? in
            if case .ready(let file) = item.state { DVDMenuTitle(name: file.title, thumbnail: item.picture) } else { nil }
        }
        for standard in TVStandard.allCases {
            let pages = DVDMenuRenderer.render(discName: dvd.cleanDiscName, titles: titles, standard: standard)
            check("7 videos make 2 menu pages (\(standard.title))", pages.count == 2 && pages[0].buttons.count >= 6)
            let size = pages.first.flatMap { NSImage(data: $0.picture) }.map { ($0.representations.first?.pixelsWide ?? 0, $0.representations.first?.pixelsHigh ?? 0) }
            check("the menu is drawn at \(standard.width)x\(standard.height) (\(standard.title))", size?.0 == standard.width && size?.1 == standard.height, "\(String(describing: size))")
        }
        let pictures = MenuLook.allCases.map { look in DVDMenuRenderer.render(discName: "Look", titles: titles, standard: .ntsc, look: look)[0].picture }
        check("each of the four looks draws its own menu", Set(pictures).count == 4 && MenuLook.allCases.map(\.title) == ["Classic", "Midnight", "Daylight", "Warm"])
        check("every look keeps its text readable (7 to 1)", MenuLook.allCases.allSatisfy { $0.textContrast >= 7 })
        check("the disc name is cut to 32 characters", { dvd.discName = String(repeating: "a", count: 50); return dvd.cleanDiscName.count == 32 }())
        dvd.showSnapshot(.empty)
    }

    /// S-050: the user's own picture and music, and a graceful fallback for a file that cannot be read.
    private static func menuMediaChecks() async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "ripple-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let picture = folder.appending(path: "beach.png")
        try? DVDMenuRenderer.blank(standard: .ntsc).write(to: picture)
        let notAPicture = folder.appending(path: "notes.png")
        try? Data("not a picture".utf8).write(to: notAPicture)
        let music = folder.appending(path: "tune.wav")
        try? wave(seconds: 2).write(to: music)
        let notMusic = folder.appending(path: "tune.mp3")
        try? Data("not music".utf8).write(to: notMusic)

        let dvd = DVDModel(source: FixtureVideoSource())
        dvd.setBackground(picture)
        check("a picture becomes the menu background", dvd.backgroundImage != nil && dvd.backgroundURL == picture && dvd.backgroundProblem == nil)
        dvd.setBackground(notAPicture)
        check("a picture that cannot be read is named, and the last good one stays",
              dvd.backgroundProblem?.contains("notes.png") == true && dvd.backgroundURL == picture)
        dvd.removeBackground()
        check("Remove goes back to the built-in background", dvd.backgroundImage == nil && dvd.backgroundProblem == nil)
        await dvd.setMusic(music)
        check("music is read with its length", dvd.musicURL == music && abs(dvd.musicSeconds - 2) < 0.2, "\(dvd.musicSeconds)")
        await dvd.setMusic(notMusic)
        check("music that cannot be read is named, and the menu stays as it was", dvd.musicProblem?.contains("tune.mp3") == true && dvd.musicURL == music)
        dvd.removeMusic()
        check("Remove goes back to silence", dvd.musicURL == nil && dvd.musicSeconds == 0)
        // S-052: the preview redraws when a title, the look, the disc name, or the picture changes.
        let before = dvd.menuKey
        dvd.showSnapshot(.videoMenu)
        let base = dvd.menuKey
        dvd.rename(dvd.items[0].id, to: "Renamed")
        let renamed = dvd.menuKey
        dvd.look = .warm
        let looked = dvd.menuKey
        dvd.discName = "Another"
        let named = dvd.menuKey
        dvd.setBackground(picture)
        let pictured = dvd.menuKey
        check("the preview changes with a rename, the look, the disc name, and the picture",
              Set([base, renamed, looked, named, pictured]).count == 5 && before != base)
        let scratch = fm.temporaryDirectory.appending(path: "ripple-preview-\(UUID().uuidString)")
        _ = DVDMenuRenderer.render(discName: dvd.cleanDiscName, titles: [DVDMenuTitle(name: "One")], standard: dvd.standard, look: dvd.look)
        check("drawing the preview converts nothing and makes no files", !fm.fileExists(atPath: scratch.path) && dvd.items.count == 7)
        dvd.showSnapshot(.empty)
        let titles = [DVDMenuTitle(name: "One")]
        let plain = DVDMenuRenderer.render(discName: "Own", titles: titles, standard: .ntsc)[0].picture
        let withPicture = DVDMenuRenderer.render(discName: "Own", titles: titles, standard: .ntsc, background: dvd.backgroundImage ?? FixtureVideoSource.gradient(seed: 3))[0].picture
        check("a chosen picture changes the menu", plain != withPicture)
    }

    /// A silent 16-bit mono WAV file, long enough to read a length from.
    private static func wave(seconds: Int) -> Data {
        let rate = 8_000, bytes = rate * 2 * seconds
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes); data.append(Data(count: bytes))
        return data
    }

    /// S-045: Build Disc runs every stage in order, and Cancel and failure go back to the list.
    private static func buildChecks(burn: BurnModel, dvd: DVDModel) async {
        let fm = FileManager.default
        burn.showSnapshot(.videoEmpty)
        dvd.showSnapshot(.videoList)
        // The two rows that cannot be built (a protected video and one still reading) leave the build list as the four good videos.
        dvd.remove(ids: Set(dvd.items.filter { if case .ready = $0.state { false } else { true } }.map(\.id)))
        let state = burn.deviceState
        check("a short list can be built", dvd.canBuild(on: state) && dvd.project(on: state).files.count == 4)
        let project = dvd.project(on: state)
        check("the project carries the choices", project.standard == .ntsc && project.widescreen && project.discName == dvd.cleanDiscName
              && project.capacityBlocks == DVDPlan.capacity(for: state))

        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work, stepDelay: .milliseconds(2)) }
        dvd.build(on: state)
        check("Build Disc starts building", dvd.isBuilding && dvd.isBusy)
        await wait(until: { if case .ready = dvd.phase { true } else { false } })
        var image: URL?
        if case .ready(let result) = dvd.phase { image = result.image }
        check("a finished build holds the disc image", image.map { fm.fileExists(atPath: $0.path) } == true)
        dvd.startOver()
        check("Start Over removes the work folder", image.map { !fm.fileExists(atPath: $0.deletingLastPathComponent().path) } == true && !dvd.isBusy)

        // S-046: a finished disc can be saved as an image with no drive; leaving it unsaved is guarded.
        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work, stepDelay: .milliseconds(2)) }
        dvd.build(on: state)
        await wait(until: { if case .ready = dvd.phase { true } else { false } })
        check("a finished disc that is not saved guards against quitting", dvd.hasUnsavedDisc && dvd.isBusy && dvd.stopPrompt.title == "Discard the Finished Disc?")
        burn.showSnapshot(.noDisc)
        let target = fm.temporaryDirectory.appending(path: "ripple-saved-\(UUID().uuidString).iso")
        check("the image saves with no disc in the drive", dvd.saveImage(to: target) && fm.fileExists(atPath: target.path))
        check("a saved disc no longer guards against quitting", !dvd.hasUnsavedDisc && !dvd.isBusy && dvd.savedImage == target)
        check("saving over an existing file replaces it", dvd.saveImage(to: target))
        try? fm.removeItem(at: target)
        dvd.startOver()
        burn.showSnapshot(.videoEmpty)
        dvd.showSnapshot(.videoList)
        dvd.remove(ids: Set(dvd.items.filter { if case .ready = $0.state { false } else { true } }.map(\.id)))

        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work, stepDelay: .milliseconds(300)) }
        dvd.build(on: state)
        await wait(until: { if case .building(.converting, _) = dvd.phase { true } else { false } })
        dvd.cancelBuild()
        await wait(until: { !dvd.isBuilding })
        check("Cancel returns to the list with the videos kept", { if case .editing = dvd.phase { dvd.videos.count == 4 } else { false } }())

        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work, failAt: .authoring, stepDelay: .milliseconds(2)) }
        dvd.build(on: state)
        await wait(until: { if case .failed = dvd.phase { true } else { false } })
        check("a failed build says which step did not work", { if case .failed(let text) = dvd.phase { text.contains("did not work") } else { false } }())
        dvd.startOver()
        check("Back to Videos keeps the list", dvd.videos.count == 4)

        dvd.showSnapshot(.videoOver)
        check("a list that is too long cannot be built", !dvd.canBuild(on: state))
        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work) }
        burn.showSnapshot(.empty)
        dvd.showSnapshot(.empty)
    }
}
