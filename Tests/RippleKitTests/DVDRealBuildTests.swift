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
        // The volume name is the disc's name, as a DVD label.
        let info = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["info", mount.path])
        XCTAssertTrue((info.output + info.error).contains("REAL_TEST"), "the volume is not named after the disc:\n\(info.output)")
        let video_ts = try FileManager.default.contentsOfDirectory(atPath: mount.appending(path: "VIDEO_TS").path)
        XCTAssertTrue(video_ts.contains("VIDEO_TS.IFO"))
        XCTAssertTrue(video_ts.contains { $0.hasPrefix("VTS_01_") && $0.hasSuffix(".VOB") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: "AUDIO_TS").path))
    }

    /// A video over 10 minutes gets chapters, so the disc gets scene pages in the titleset's menus. Slow (about a minute).
    func testALongVideoGetsSceneMenusThatTheRealDvdauthorAccepts() async throws {
        let root = DVDTestTools.root.appending(path: ".dvdtools")
        let ffmpeg = root.appending(path: "ffmpeg"), dvdauthor = root.appending(path: "dvdauthor/bin/dvdauthor"), spumux = root.appending(path: "dvdauthor/bin/spumux")
        for tool in [ffmpeg, dvdauthor, spumux] where !FileManager.default.isExecutableFile(atPath: tool.path) { throw XCTSkip("\(tool.lastPathComponent) is not built") }
        let folder = try DVDTestTools.tempFolder("ripple-real-scenes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "Long.mov")
        try await DVDTestTools.makeVideo(video, seconds: 660, size: "320x180", rate: 5)
        guard case .success(let file) = try await VideoProbe.read(video, ffmpeg: ffmpeg) else { return XCTFail("the sample video was not readable") }
        let project = DVDProject(files: [file], discName: "Scenes Test", standard: .ntsc, widescreen: true)
        let result = try await DVDBuilder(tools: DVDTools(ffmpeg: ffmpeg, dvdauthor: dvdauthor, spumux: spumux), project: project, work: folder.appending(path: "work")).build { _, _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.image.path))
        // The titleset's own menu file exists only when the scene pages were written.
        let mount = folder.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, result.image.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        defer { Task { _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"]) } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: "VIDEO_TS/VTS_01_0.VOB").path), "the scene menus are missing from the disc")
    }
}

private extension VideoFile {
    func titled(_ name: String) -> VideoFile { var copy = self; copy.title = name; return copy }
}

/// Each common container, made by the real ffmpeg, is read by `VideoProbe` and converted to DVD video by the real command.
final class DVDRealFormatTests: XCTestCase {
    func testEveryCommonVideoFormatReadsAndConverts() async throws {
        guard let ffmpeg = DVDTestTools.ffmpeg else { throw XCTSkip("no ffmpeg in .dvdtools") }
        let folder = try DVDTestTools.tempFolder("ripple-formats")
        defer { try? FileManager.default.removeItem(at: folder) }
        // (ending, video codec, audio codec): what each container usually holds.
        let formats: [(String, String, String)] = [
            ("mov", "mpeg4", "aac"), ("mp4", "mpeg4", "aac"), ("m4v", "mpeg4", "aac"), ("avi", "mpeg4", "mp3"), ("mkv", "mpeg4", "aac"),
            ("wmv", "wmv2", "wmav2"), ("mpg", "mpeg2video", "mp2"), ("mpeg", "mpeg1video", "mp2"), ("webm", "libvpx", "libvorbis"),
            ("flv", "flv", "aac"), ("ts", "mpeg2video", "mp2"), ("3gp", "h263", "aac"),
        ]
        var worked: [String] = [], skipped: [String] = [], failed: [String] = []
        for (ending, video, audio) in formats {
            let source = folder.appending(path: "sample.\(ending)")
            let size = video == "h263" ? "352x288" : "640x360"
            let made = try await ProcessRunner.run(ffmpeg, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=3:size=\(size):rate=25",
                                                            "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", video, "-c:a", audio, source.path])
            guard made.status == 0 else { skipped.append(ending); continue }   // this ffmpeg cannot make that kind of file
            guard VideoProbe.isVideoFile(source), case .success(let file) = try await VideoProbe.read(source, ffmpeg: ffmpeg) else { failed.append("\(ending): not read"); continue }
            let out = folder.appending(path: "out-\(ending).mpg")
            let geometry = DVDGeometry.fit(displayAspect: file.displayAspect, widescreen: file.isWidescreen, standard: .ntsc)
            let converted = try await ProcessRunner.run(ffmpeg, DVDAuthoring.convertArguments(input: source, output: out, geometry: geometry, standard: .ntsc, videoKbps: 5_000, hasAudio: file.hasAudio))
            let bytes = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if converted.status == 0 && bytes > 10_000 { worked.append(ending) } else { failed.append("\(ending): \(converted.error.suffix(120))") }
        }
        print("DVD formats converted: \(worked.joined(separator: ", ")). Not made by this ffmpeg: \(skipped.joined(separator: ", ")).")
        XCTAssertTrue(failed.isEmpty, failed.joined(separator: "\n"))
        for ending in ["mov", "mp4", "avi", "mkv", "mpg"] { XCTAssertTrue(worked.contains(ending), "\(ending) must work") }
    }
}
