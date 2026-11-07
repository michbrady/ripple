import Foundation
import XCTest
@testable import RippleKit

/// A Blu-ray image made with the real ffmpeg and tsMuxeR. Skips when `.dvdtools` has not been filled
/// (tools/fetch-ffmpeg.sh and tools/fetch-tsmuxer.sh).
final class BluRayRealBuildTests: XCTestCase {
    func testTwoVideosBecomeOneBluRayImage() async throws {
        let root = DVDTestTools.root.appending(path: ".dvdtools")
        let ffmpeg = root.appending(path: "ffmpeg"), tsmuxer = root.appending(path: "tsMuxeR")
        for tool in [ffmpeg, tsmuxer] where !FileManager.default.isExecutableFile(atPath: tool.path) { throw XCTSkip("\(tool.lastPathComponent) is not fetched") }
        let folder = try DVDTestTools.tempFolder("ripple-bluray")
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "Beach Day.mov")
        try await DVDTestTools.makeVideo(video, seconds: 4, size: "1280x720", rate: 30)
        guard case .success(let file) = try await VideoProbe.read(video, ffmpeg: ffmpeg) else { return XCTFail("the sample video was not readable") }
        let silent = folder.appending(path: "Quiet.mov")
        try await DVDTestTools.makeVideo(silent, seconds: 3, size: "640x360", rate: 24, audio: false)
        guard case .success(let quiet) = try await VideoProbe.read(silent, ffmpeg: ffmpeg) else { return XCTFail("the silent video was not readable") }

        let project = DVDProject(files: [file, quiet], discName: "Blu Test", standard: .ntsc, widescreen: true, format: .bluray)
        let result = try await BluRayBuilder(tools: BluRayTools(ffmpeg: ffmpeg, tsmuxer: tsmuxer), project: project, work: folder.appending(path: "work")).build { _, _ in }
        XCTAssertEqual(result.titles, 2)
        let mount = folder.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, result.image.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        defer { Task { _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"]) } }
        for path in ["BDMV/index.bdmv", "BDMV/MovieObject.bdmv"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: path).path), "\(path) is missing from the disc")
        }
        let streams = (try? FileManager.default.contentsOfDirectory(atPath: mount.appending(path: "BDMV/STREAM").path)) ?? []
        XCTAssertTrue(streams.contains { $0.hasSuffix(".m2ts") }, "no video stream on the disc")
        let info = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["info", mount.path])
        XCTAssertTrue((info.output + info.error).contains("BLU_TEST"), "the volume is not named after the disc:\n\(info.output)")
        // Playlist 00000 holds both videos: its chapters (marks) are one at the start of each.
        let playlist = try Data(contentsOf: mount.appending(path: "BDMV/PLAYLIST/00000.mpls"))
        XCTAssertGreaterThan(playlist.count, 60)
        let markStart = playlist.subdata(in: 12..<16).reduce(0) { $0 << 8 | Int($1) }
        let marks = Int(playlist[markStart + 4]) << 8 | Int(playlist[markStart + 5])
        XCTAssertEqual(marks, 2, "the playlist should have one chapter for each video")
        // A title for each video too: playlists 00001 and 00002 each play one video's part of the stream.
        for name in ["00001", "00002"] { XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appending(path: "BDMV/PLAYLIST/\(name).mpls").path), "\(name).mpls is missing") }
        // libbluray, the library VLC uses, is the independent reader: it lists "play everything" and one title for each video.
        if let reader = ["/opt/homebrew/bin/bd_list_titles", "/usr/local/bin/bd_list_titles"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let listed = try await ProcessRunner.run(URL(fileURLWithPath: reader), ["-a", result.image.path])
            if let info = ["/opt/homebrew/bin/bd_info", "/usr/local/bin/bd_info"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                let described = try await ProcessRunner.run(URL(fileURLWithPath: info), [result.image.path])
                XCTAssertTrue(described.output.contains("HDMV titles         : 3") && described.output.contains("First Play supported: yes")
                              && described.output.contains("Top menu supported  : yes"), described.output + described.error)
            }
            let lines = listed.output.split(separator: "\n").filter { $0.hasPrefix("index:") }
            XCTAssertEqual(lines.count, 3, "libbluray should list three titles:\n\(listed.output)\n\(listed.error)")
            if lines.count == 3 {
                XCTAssertTrue(lines[0].contains("chapters:   2") && lines[0].contains("00000.mpls"), "\(lines[0])")
                XCTAssertTrue(lines[1].contains("chapters:   1") && lines[1].contains("00001.mpls") && lines[1].contains("00:00:04"), "\(lines[1])")
                XCTAssertTrue(lines[2].contains("chapters:   1") && lines[2].contains("00002.mpls") && lines[2].contains("00:00:03"), "\(lines[2])")
            }
        }
        // The stream is HD H.264 with AC-3 sound, about as long as both videos together.
        let stream = mount.appending(path: "BDMV/STREAM/\(streams.sorted().first { $0.hasSuffix(".m2ts") }!)")
        let probe = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-i", stream.path])
        let text = probe.error + probe.output
        XCTAssertTrue(text.contains("h264") && text.contains("1920x1080") && text.contains("ac3"), text)
        XCTAssertEqual(VideoProbe.seconds(in: text) ?? 0, 7, accuracy: 1)
    }
}
