import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RippleKit

/// The whole pipeline against stand-in ffmpeg, spumux, and dvdauthor scripts, and the real hdiutil.
final class DVDBuilderTests: XCTestCase {
    struct Sandbox {
        let root: URL, log: URL, outputs: URL
        var tools: DVDTools
    }

    func script(_ dir: URL, _ name: String, _ body: String) throws -> URL {
        let url = dir.appending(path: name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `ffmpegBody` runs for the stand-in ffmpeg; the helpers below are its usual behaviors.
    func sandbox(ffmpegBody: String? = nil) throws -> Sandbox {
        let root = try DVDTestTools.tempFolder("ripple-builder")
        let bin = root.appending(path: "bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = root.appending(path: "calls.log"), outputs = root.appending(path: "out")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        // A real small PNG for thumbnails.
        let ctx = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        let dest = CGImageDestinationCreateWithURL(bin.appending(path: "thumb.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        let ffmpeg = try script(bin, "ffmpeg", ffmpegBody ?? """
        echo "ffmpeg $@" >> '\(log.path)'
        for last; do :; done
        case "$*" in
          *-progress*) echo out_time_us=1000000; echo out_time_us=2000000; echo out_time_us=3000000; printf mpeg > "$last" ;;
          *-frames:v*) cp '\(bin.path)/thumb.png' "$last" ;;
          *-i\\ *music*) echo "  Duration: 00:00:42.00, start: 0" >&2 ;;
          *) printf menu > "$last" ;;
        esac
        """)
        let spumux = try script(bin, "spumux", "echo \"spumux $@ VIDEO_FORMAT=$VIDEO_FORMAT\" >> '\(log.path)'\ncat")
        let dvdauthor = try script(bin, "dvdauthor", """
        echo "dvdauthor $@ VIDEO_FORMAT=$VIDEO_FORMAT" >> '\(log.path)'
        while [ $# -gt 0 ]; do [ "$1" = "-o" ] && dir="$2"; shift; done
        mkdir -p "$dir/VIDEO_TS"; printf ifo > "$dir/VIDEO_TS/VIDEO_TS.IFO"; printf ifo > "$dir/VIDEO_TS/VTS_01_0.IFO"; printf vob > "$dir/VIDEO_TS/VTS_01_1.VOB"
        """)
        return Sandbox(root: root, log: log, outputs: outputs, tools: DVDTools(ffmpeg: ffmpeg, dvdauthor: dvdauthor, spumux: spumux))
    }

    func video(_ name: String, seconds: Double = 30, fps: Double = 29.97, aspect: Double = 16.0 / 9, hasAudio: Bool = true) -> VideoFile {
        VideoFile(url: URL(fileURLWithPath: "/tmp/\(name).mp4"), title: name, bytes: 1, seconds: seconds, width: 1280, height: 720, framesPerSecond: fps, displayAspect: aspect, hasAudio: hasAudio)
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(DVDBuildStage, Double)] = []
        func add(_ s: DVDBuildStage, _ p: Double) { lock.withLock { items.append((s, p)) } }
        var all: [(DVDBuildStage, Double)] { lock.withLock { items } }
    }

    func testTheWholeDiscIsBuiltInOrder() async throws {
        let box = try sandbox()
        let project = DVDProject(files: [video("First"), video("Second", seconds: 60)], discName: "Summer Trip", standard: .ntsc, widescreen: true)
        let events = Events()
        let result = try await DVDBuilder(tools: box.tools, project: project, work: box.root.appending(path: "work")).build { events.add($0, $1) }
        XCTAssertEqual(result.titles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.image.path))
        // The stages come in order, and the overall progress never goes backwards and ends at 1.
        let stages = events.all.map(\.0)
        XCTAssertEqual(stages.first, .checking); XCTAssertEqual(stages.last, .done)
        func index(_ match: (DVDBuildStage) -> Bool) -> Int? { stages.firstIndex(where: match) }
        let pictures = index { $0 == .pictures }, menus = index { $0 == .menus }
        let converting = index { if case .converting = $0 { true } else { false } }, authoring = index { $0 == .authoring }, imaging = index { $0 == .imaging }
        XCTAssertEqual([pictures, menus, converting, authoring, imaging].compactMap { $0 }.sorted(), [pictures, menus, converting, authoring, imaging].compactMap { $0 })
        let overall = events.all.map(\.1)
        XCTAssertEqual(overall, overall.sorted()); XCTAssertEqual(overall.last, 1)
        XCTAssertTrue(stages.contains(.converting(title: 2, of: 2, name: "Second", fraction: 0)))
        // What the programs were told.
        let log = try String(contentsOf: box.log, encoding: .utf8)
        XCTAssertTrue(log.contains("VIDEO_FORMAT=NTSC"))
        XCTAssertEqual(log.components(separatedBy: "-progress").count - 1, 2)       // two titles converted
        XCTAssertTrue(log.contains("spumux buttons1.xml")); XCTAssertTrue(log.contains("dvdauthor -o"))
        // The disc description was kept for a look, and the converted videos were cleared.
        let xml = try String(contentsOf: result.work.appending(path: "dvd.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("titles/title2.mpg")); XCTAssertTrue(xml.contains("menu/menu1.mpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.work.appending(path: "titles").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.work.appending(path: "disc").path))
    }

    func testTheImageHoldsAVideoTSFolder() async throws {
        let box = try sandbox()
        let project = DVDProject(files: [video("Clip")], discName: "My Disc: 1", standard: .pal, widescreen: false)
        let result = try await DVDBuilder(tools: box.tools, project: project, work: box.root.appending(path: "work")).build { _, _ in }
        let mount = box.root.appending(path: "mount")
        let attach = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", result.image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mount.path, "-force"]) }
        let top = try FileManager.default.contentsOfDirectory(atPath: mount.path)
        XCTAssertTrue(top.contains("VIDEO_TS")); XCTAssertTrue(top.contains("AUDIO_TS"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: "VIDEO_TS/VIDEO_TS.IFO").path))
        let info = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["imageinfo", result.image.path])
        XCTAssertTrue((info.output + info.error).contains("UDF") || (info.output + info.error).contains("ISO"), info.output)
        let volume = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["info", mount.path])
        XCTAssertTrue(volume.output.contains("MY_DISC_1"), volume.output)
        XCTAssertTrue(try String(contentsOf: box.log, encoding: .utf8).contains("VIDEO_FORMAT=PAL"))
    }

    func testAFailureNamesTheVideoAndCleansUp() async throws {
        let box = try sandbox(ffmpegBody: """
        for last; do :; done
        case "$*" in
          *-progress*/tmp/B.mp4*) echo "Error opening input: Invalid data" >&2; exit 1 ;;
          *-progress*) printf mpeg > "$last" ;;
          *-frames:v*) cp "$(dirname "$0")/thumb.png" "$last" ;;
          *) printf menu > "$last" ;;
        esac
        """)
        let project = DVDProject(files: [video("A"), video("B")], discName: "D", standard: .ntsc, widescreen: true)
        let work = box.root.appending(path: "work")
        do {
            _ = try await DVDBuilder(tools: box.tools, project: project, work: work).build { _, _ in }
            XCTFail("expected a failure")
        } catch let DVDBuildError.failed(step, detail) {
            XCTAssertTrue(step.contains("Converting"), step); XCTAssertTrue(step.contains("B"))
            XCTAssertTrue(detail.contains("Invalid data"), detail)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testAFailingDiscToolIsReported() async throws {
        var box = try sandbox()
        box.tools.dvdauthor = try script(box.root.appending(path: "bin"), "dvdauthor", "echo 'ERR: bad menu' >&2; exit 1")
        let project = DVDProject(files: [video("A")], discName: "D", standard: .ntsc, widescreen: true)
        do {
            _ = try await DVDBuilder(tools: box.tools, project: project, work: box.root.appending(path: "work")).build { _, _ in }
            XCTFail("expected a failure")
        } catch let DVDBuildError.failed(step, detail) {
            XCTAssertEqual(step, "Writing the disc files"); XCTAssertTrue(detail.contains("bad menu"))
        }
    }

    func testCancellingStopsTheConverterAndLeavesNothing() async throws {
        let box = try sandbox(ffmpegBody: """
        for last; do :; done
        case "$*" in
          *-progress*) echo started >> '\(DVDTestTools.root.path)/.dvdtools/cancel-marker' ; sleep 30 ;;
          *-frames:v*) cp "$(dirname "$0")/thumb.png" "$last" ;;
          *) printf menu > "$last" ;;
        esac
        """)
        let work = box.root.appending(path: "work")
        let project = DVDProject(files: [video("A")], discName: "D", standard: .ntsc, widescreen: true)
        let task = Task { try await DVDBuilder(tools: box.tools, project: project, work: work).build { _, _ in } }
        try await Task.sleep(for: .seconds(1.5))
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        try? FileManager.default.removeItem(at: DVDTestTools.root.appending(path: ".dvdtools/cancel-marker"))
    }

    func testProblemsAreSaidBeforeAnythingStarts() async throws {
        let box = try sandbox()
        let work = box.root.appending(path: "work")
        func run(_ project: DVDProject, tools: DVDTools? = nil) async -> DVDBuildError? {
            do { _ = try await DVDBuilder(tools: tools ?? box.tools, project: project, work: work).build { _, _ in }; return nil } catch { return error as? DVDBuildError }
        }
        let empty = await run(DVDProject(files: [], discName: "D", standard: .ntsc, widescreen: true))
        XCTAssertEqual(empty, .nothingToBuild)
        let long = await run(DVDProject(files: [video("L", seconds: 6 * 3_600)], discName: "D", standard: .ntsc, widescreen: true))
        XCTAssertEqual(long, .tooLong)
        let many = await run(DVDProject(files: (0..<100).map { video("v\($0)", seconds: 10) }, discName: "D", standard: .ntsc, widescreen: true))
        XCTAssertEqual(many, .tooManyTitles)
        var missing = box.tools; missing.spumux = URL(fileURLWithPath: "/nonexistent/spumux")
        let gone = await run(DVDProject(files: [video("A")], discName: "D", standard: .ntsc, widescreen: true), tools: missing)
        XCTAssertEqual(gone, .toolMissing("spumux"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appending(path: "titles").path))
        XCTAssertTrue(DVDBuildError.tooLong.localizedDescription.contains("too long"))
    }

    func testMenuMusicSetsTheMenuLength() async throws {
        let box = try sandbox(ffmpegBody: """
        for last; do :; done
        case "$*" in
          *-progress*) printf mpeg > "$last" ;;
          *-frames:v*) cp "$(dirname "$0")/thumb.png" "$last" ;;
          *loop*) echo "$*" >> "$(dirname "$0")/../menu-calls.log"; printf menu > "$last" ;;
          *) echo "  Duration: 00:02:30.00, start: 0" >&2 ;;
        esac
        """)
        let music = box.root.appending(path: "song.mp3")
        let project = DVDProject(files: [video("A")], discName: "D", standard: .ntsc, widescreen: true, music: music)
        _ = try await DVDBuilder(tools: box.tools, project: project, work: box.root.appending(path: "work")).build { _, _ in }
        let calls = try String(contentsOf: box.root.appending(path: "menu-calls.log"), encoding: .utf8)
        XCTAssertTrue(calls.contains("-t 90 "), calls)            // 2:30 of music is cut to 90 seconds
        XCTAssertTrue(calls.contains("-stream_loop -1 -i \(music.path)"), calls)
    }
}
