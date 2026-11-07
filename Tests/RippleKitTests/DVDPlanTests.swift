import Foundation
import XCTest
@testable import RippleKit

/// The ffmpeg that Ripple's DVD feature uses, found from this source file. Tests that need it skip when it is missing.
enum DVDTestTools {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var ffmpeg: URL? {
        let url = root.appending(path: ".dvdtools/ffmpeg")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    static func tempFolder(_ name: String = "ripple-dvd") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A short test video with a tone, made by ffmpeg itself.
    static func makeVideo(_ file: URL, seconds: Int = 3, size: String = "640x360", rate: Int = 30, codecs: [String] = ["-c:v", "mpeg4", "-c:a", "aac"], audio: Bool = true) async throws {
        guard let ffmpeg else { throw XCTSkip("no ffmpeg in .dvdtools") }
        var args = ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=\(size):rate=\(rate)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"] }
        args += codecs + [file.path]
        if !audio { args = args.filter { $0 != "-c:a" && $0 != "aac" } }
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0 else { throw XCTSkip("ffmpeg could not make \(file.lastPathComponent): \(result.error)") }
    }
}

final class DVDPlanTests: XCTestCase {
    func file(_ name: String, seconds: Double, fps: Double = 29.97, aspect: Double = 16.0 / 9) -> VideoFile {
        VideoFile(url: URL(fileURLWithPath: "/tmp/\(name).mp4"), title: name, bytes: 1_000_000, seconds: seconds, width: 1280, height: 720,
                  framesPerSecond: fps, displayAspect: aspect, hasAudio: true)
    }

    // MARK: Reading ffmpeg's report

    let mp4Report = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'trip.mp4':
      Duration: 00:01:30.50, start: 0.000000, bitrate: 1060 kb/s
      Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1280x720 [SAR 1:1 DAR 16:9], 1000 kb/s, 29.97 fps, 29.97 tbr, 30k tbn (default)
      Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s (default)
    """

    func testReadsLengthSizeRateShapeAndAudio() throws {
        let video = try VideoProbe.parse(report: mp4Report, url: URL(fileURLWithPath: "/x/Summer_trip_2024.mp4"), bytes: 123).get()
        XCTAssertEqual(video.seconds, 90.5, accuracy: 0.001)
        XCTAssertEqual(video.width, 1280); XCTAssertEqual(video.height, 720)
        XCTAssertEqual(video.framesPerSecond, 29.97, accuracy: 0.001)
        XCTAssertEqual(video.displayAspect, 16.0 / 9, accuracy: 0.001)
        XCTAssertTrue(video.hasAudio); XCTAssertTrue(video.isWidescreen)
        XCTAssertEqual(video.title, "Summer trip 2024")
    }

    func testTheHexTagIsNotThePictureSize() throws {
        let video = try VideoProbe.parse(report: mp4Report, url: URL(fileURLWithPath: "/x/a.mp4"), bytes: 1).get()
        XCTAssertEqual(video.width, 1280)   // not 0x31637661
    }

    func testNonSquarePixelsChangeTheShape() throws {
        let report = "Duration: 00:00:10.00, start: 0\n  Stream #0:0: Video: mpeg2video (Main), yuv420p, 720x480 [SAR 8:9 DAR 4:3], 29.97 fps\n  Stream #0:1: Audio: ac3, 48000 Hz"
        let video = try VideoProbe.parse(report: report, url: URL(fileURLWithPath: "/x/old.mpg"), bytes: 1).get()
        XCTAssertEqual(video.displayAspect, 4.0 / 3, accuracy: 0.001)
        XCTAssertFalse(video.isWidescreen)
        let noDAR = "Duration: 00:00:10.00\n  Stream #0:0: Video: h264, yuv420p, 640x480 [SAR 1:1], 25 fps"
        XCTAssertEqual(try VideoProbe.parse(report: noDAR, url: URL(fileURLWithPath: "/x/a.avi"), bytes: 1).get().displayAspect, 4.0 / 3, accuracy: 0.001)
    }

    func testAMusicFilesCoverPictureIsNotVideo() {
        let report = "Duration: 00:03:00.00\n  Stream #0:0: Audio: mp3, 44100 Hz\n  Stream #0:1: Video: mjpeg, yuvj420p, 500x500 [SAR 1:1 DAR 1:1], 90k tbr (attached pic)"
        XCTAssertEqual(VideoProbe.parse(report: report, url: URL(fileURLWithPath: "/x/s.mp3"), bytes: 1), .failure(.noPicture))
    }

    func testProblemsAreNamed() {
        let url = URL(fileURLWithPath: "/x/a.mov")
        XCTAssertEqual(VideoProbe.parse(report: "garbage", url: url, bytes: 1), .failure(.unreadable))
        XCTAssertEqual(VideoProbe.parse(report: "Duration: 00:00:00.20\n Stream #0:0: Video: h264, 640x480, 30 fps", url: url, bytes: 1), .failure(.tooShort))
        let drm = "Duration: 01:00:00.00\n  Stream #0:0: Video: none (drmi / 0x696D7264), 1920x1080\n  Stream #0:1: Audio: drms"
        XCTAssertEqual(VideoProbe.parse(report: drm, url: url, bytes: 1), .failure(.copyProtected))
        XCTAssertTrue(VideoProblem.copyProtected.message.contains("copy-protected"))
    }

    func testWhichFilesAreOffered() {
        for name in ["a.mov", "a.MP4", "a.m4v", "a.avi", "a.mkv", "a.wmv", "a.webm", "a.flv"] {
            XCTAssertTrue(VideoProbe.isVideoFile(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["a.mp3", "a.jpg", "a.txt", "a"] { XCTAssertFalse(VideoProbe.isVideoFile(URL(fileURLWithPath: "/x/\(name)")), name) }
    }

    func testNamesAreCleanedAndCut() {
        XCTAssertEqual(DVDName.cleaned("  My   \n holiday  ", fallback: "Video"), "My holiday")
        XCTAssertEqual(DVDName.cleaned("   ", fallback: "Video"), "Video")
        XCTAssertEqual(DVDName.cleaned(String(repeating: "a", count: 100), fallback: "x").count, DVDName.maxTitle)
        XCTAssertEqual(DVDName.volumeLabel("Summer Trip: 2024!"), "SUMMER_TRIP_2024")
        XCTAssertEqual(DVDName.volumeLabel("???"), "VIDEO_DVD")
        XCTAssertLessThanOrEqual(DVDName.volumeLabel(String(repeating: "A", count: 80)).count, 32)
    }

    // MARK: TV standard

    func testPalForTwentyFiveAndFiftyFramesNtscForTheRest() {
        XCTAssertEqual(TVStandard.suggest(for: [file("a", seconds: 5, fps: 25)]), .pal)
        XCTAssertEqual(TVStandard.suggest(for: [file("a", seconds: 5, fps: 50)]), .pal)
        for fps in [23.976, 24, 29.97, 30, 59.94, 60] { XCTAssertEqual(TVStandard.suggest(for: [file("a", seconds: 5, fps: fps)]), .ntsc, "\(fps)") }
        XCTAssertEqual(TVStandard.suggest(for: []), .ntsc)
        XCTAssertTrue(TVStandard.mixed([file("a", seconds: 5, fps: 25), file("b", seconds: 5, fps: 30)]))
        XCTAssertFalse(TVStandard.mixed([file("a", seconds: 5, fps: 24), file("b", seconds: 5, fps: 30)]))
        XCTAssertEqual(TVStandard.ntsc.height, 480); XCTAssertEqual(TVStandard.pal.height, 576)
    }

    // MARK: Fit and quality

    func testTwoHoursOnOneLayerLooksExcellentOrGood() {
        let plan = DVDPlan(files: [file("movie", seconds: 2 * 3_600)], standard: .ntsc)
        XCTAssertGreaterThan(plan.videoKbps, 3_500)
        XCTAssertLessThanOrEqual(plan.videoKbps, DVDPlan.maxVideoKbps)
        XCTAssertEqual(plan.fit, .fits)
        XCTAssertLessThanOrEqual(plan.blocksNeeded, DVDPlan.singleLayerBlocks)
    }

    func testAShortVideoIsCappedAtTheDVDLimit() {
        let plan = DVDPlan(files: [file("clip", seconds: 600)], standard: .ntsc)
        XCTAssertEqual(plan.videoKbps, 9_000)
        XCTAssertEqual(plan.quality, .excellent)
        XCTAssertLessThan(plan.blocksNeeded, DVDPlan.singleLayerBlocks / 2)
    }

    func testTheBandsAndTheirLimits() {
        XCTAssertEqual(DVDQuality.of(videoKbps: 5_000), .excellent)
        XCTAssertEqual(DVDQuality.of(videoKbps: 4_999), .good)
        XCTAssertEqual(DVDQuality.of(videoKbps: 3_500), .good)
        XCTAssertEqual(DVDQuality.of(videoKbps: 2_500), .reduced)
        XCTAssertEqual(DVDQuality.of(videoKbps: 2_499), .tooLong)
        XCTAssertEqual(DVDQuality.excellent.title, "Excellent")
    }

    func testTooMuchSaysHowMuchToRemove() {
        let plan = DVDPlan(files: [file("a", seconds: 3 * 3_600), file("b", seconds: 2 * 3_600)], standard: .ntsc)
        guard case .tooLong(let removeSeconds) = plan.fit else { return XCTFail("expected too long") }
        XCTAssertGreaterThan(removeSeconds, 3_600)
        // Removing what it says brings the total down to the longest length that fits.
        let limit = plan.longestReducedSeconds
        XCTAssertEqual(plan.totalSeconds - removeSeconds, limit, accuracy: 0.001)
        XCTAssertEqual(DVDPlan(files: [file("a", seconds: limit - 1)], standard: .ntsc).fit, .fits)
        XCTAssertNotEqual(DVDPlan(files: [file("a", seconds: limit + 5)], standard: .ntsc).fit, .fits)
    }

    func testADualLayerDiscHoldsAboutTwiceAsMuch() {
        let long = [file("a", seconds: 5 * 3_600)]
        XCTAssertNotEqual(DVDPlan(files: long, standard: .ntsc).fit, .fits)
        XCTAssertEqual(DVDPlan(files: long, standard: .ntsc, capacityBlocks: DVDPlan.dualLayerBlocks).fit, .fits)
    }

    func testCapacityComesFromTheDiscInTheDrive() {
        XCTAssertEqual(DVDPlan.capacity(for: .noDisc), DVDPlan.singleLayerBlocks)
        XCTAssertEqual(DVDPlan.capacity(for: .ready(BurnMedia(kind: .dvd, label: "DVD+R DL", blocksFree: 4_000_000))), 4_000_000)
        XCTAssertEqual(DVDPlan.capacity(for: .ready(BurnMedia(kind: .cd, label: "CD-R", blocksFree: 350_000))), DVDPlan.singleLayerBlocks)
    }

    func testNothingToBurn() {
        XCTAssertEqual(DVDPlan(files: [], standard: .ntsc).fit, .nothingToBurn)
        XCTAssertEqual(DVDPlan(files: [], standard: .ntsc).blocksNeeded, 0)
        XCTAssertEqual(DVDPlan.lengthText(3_725), "1:02:05")
        XCTAssertEqual(DVDPlan.lengthText(214), "3:34")
    }

    // MARK: A real ffmpeg reads real files

    func testRealVideosInManyFormatsAreRead() async throws {
        let dir = try DVDTestTools.tempFolder()
        let ffmpeg = try XCTUnwrap(DVDTestTools.ffmpeg, "no ffmpeg in .dvdtools")
        let cases: [(String, [String])] = [
            ("a.mov", ["-c:v", "mpeg4", "-c:a", "aac"]), ("b.mp4", ["-c:v", "mpeg4", "-c:a", "aac"]), ("c.avi", ["-c:v", "mpeg4", "-c:a", "mp3"]),
            ("d.mkv", ["-c:v", "mpeg4", "-c:a", "aac"]), ("e.wmv", ["-c:v", "wmv2", "-c:a", "wmav2"]), ("f.mpg", ["-c:v", "mpeg2video", "-c:a", "mp2"]),
        ]
        for (name, codecs) in cases {
            let url = dir.appending(path: name)
            try await DVDTestTools.makeVideo(url, seconds: 3, codecs: codecs)
            let video = try await VideoProbe.read(url, ffmpeg: ffmpeg).get()
            XCTAssertEqual(video.seconds, 3, accuracy: 0.3, name)
            XCTAssertEqual(video.width, 640, name); XCTAssertEqual(video.height, 360, name)
            XCTAssertEqual(video.framesPerSecond, 30, accuracy: 0.5, name)
            XCTAssertTrue(video.hasAudio, name); XCTAssertTrue(video.isWidescreen, name)
        }
        let silent = dir.appending(path: "silent.mp4")
        try await DVDTestTools.makeVideo(silent, audio: false)
        let silentVideo = try await VideoProbe.read(silent, ffmpeg: ffmpeg).get()
        XCTAssertFalse(silentVideo.hasAudio)
        let text = dir.appending(path: "not-video.mp4")
        try Data("this is not a video".utf8).write(to: text)
        let notVideo = try await VideoProbe.read(text, ffmpeg: ffmpeg)
        XCTAssertEqual(notVideo, .failure(.unreadable))
    }
}
