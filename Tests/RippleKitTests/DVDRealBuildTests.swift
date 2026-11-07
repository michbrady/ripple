import Foundation
import XCTest
@testable import RippleKit

/// The whole pipeline with the real programs: ffmpeg, spumux, dvdauthor, and hdiutil. Skips when `.dvdtools` has not been filled
/// (tools/fetch-ffmpeg.sh and tools/build-dvdauthor.sh).
final class DVDRealBuildTests: XCTestCase {
    func testARealVideoBecomesARealDiscImage() async throws {
        let root = DVDTestTools.root.appending(path: ".dvdtools")
        let ffmpeg = root.appending(path: "ffmpeg"), dvdauthor = root.appending(path: "dvdauthor/bin/dvdauthor"), spumux = root.appending(path: "dvdauthor/bin/spumux")
        for tool in [ffmpeg, dvdauthor, spumux] where !FileManager.default.isExecutableFile(atPath: tool.path) { throw XCTSkip("\(tool.lastPathComponent) is not built") }

        let folder = try DVDTestTools.tempFolder("ripple-real")
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "Beach Day.mov")
        try await DVDTestTools.makeVideo(video, seconds: 4)
        guard case .success(let file) = try await VideoProbe.read(video, ffmpeg: ffmpeg) else { return XCTFail("the sample video was not readable") }

        let project = DVDProject(files: [file, file.titled("Second")], discName: "Real Test", standard: .ntsc, widescreen: true)
        let work = folder.appending(path: "work")
        let result = try await DVDBuilder(tools: DVDTools(ffmpeg: ffmpeg, dvdauthor: dvdauthor, spumux: spumux), project: project, work: work).build { _, _ in }
        XCTAssertEqual(result.titles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.image.path))

        // Mount the image and look inside: the disc's folders and the volume name.
        let mount = folder.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, result.image.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        defer { Task { _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"]) } }
        let video_ts = try FileManager.default.contentsOfDirectory(atPath: mount.appending(path: "VIDEO_TS").path)
        XCTAssertTrue(video_ts.contains("VIDEO_TS.IFO"))
        XCTAssertTrue(video_ts.contains { $0.hasPrefix("VTS_01_") && $0.hasSuffix(".VOB") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: "AUDIO_TS").path))
    }
}

private extension VideoFile {
    func titled(_ name: String) -> VideoFile { var copy = self; copy.title = name; return copy }
}
