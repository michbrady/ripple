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
}
