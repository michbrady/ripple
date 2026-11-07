import Foundation
import Testing
@testable import RippleKit

@Suite struct BluRayPlanTests {
    func video(_ seconds: Double, fps: Double = 24) -> VideoFile {
        VideoFile(url: URL(fileURLWithPath: "/tmp/v.mp4"), title: "v", bytes: 1, seconds: seconds, width: 1920, height: 1080, framesPerSecond: fps, displayAspect: 16.0 / 9, hasAudio: true)
    }

    @Test func aTwoHourFilmIsExcellentOnOneDisc() {
        let plan = DVDPlan(files: [video(7_200)], standard: .ntsc, format: .bluray)
        #expect(plan.capacityBlocks == 12_219_392)
        #expect(plan.quality == .excellent && plan.fit == .fits)
        #expect(plan.videoKbps == 20_000)
    }

    @Test func aVeryLongRunIsTooLongForOneDiscButFitsADualLayerOne() {
        let files = [video(12 * 3_600)]   // twelve hours
        #expect(DVDPlan(files: files, standard: .ntsc, format: .bluray).fit != .fits)
        #expect(DVDPlan(files: files, standard: .ntsc, capacityBlocks: VideoDiscFormat.bluray.dualLayerBlocks, format: .bluray).fit == .fits)
    }

    @Test func theDVDPlanIsUnchanged() {
        let plan = DVDPlan(files: [video(3_600)], standard: .ntsc)
        #expect(plan.format == .dvd && plan.capacityBlocks == DVDPlan.singleLayerBlocks)
        #expect(plan.videoKbps == 9_000)
    }

    @Test func capacityComesFromABluRayInTheDriveOnly() {
        let bd = BurnDeviceState.ready(BurnMedia(kind: .bluray, label: "BD-R DL", blocksFree: 24_000_000))
        let dvd = BurnDeviceState.ready(BurnMedia(kind: .dvd, label: "DVD-R", blocksFree: 2_000_000))
        #expect(DVDPlan.capacity(for: bd, format: .bluray) == 24_000_000)
        #expect(DVDPlan.capacity(for: dvd, format: .bluray) == VideoDiscFormat.bluray.singleLayerBlocks)
        #expect(DVDPlan.capacity(for: bd, format: .dvd) == DVDPlan.singleLayerBlocks)
    }

    @Test func theFrameRateDecidesTheDiscShape() {
        #expect(BluRayMode.suggest(for: [video(10, fps: 23.976)]).title == "1080p23.976")
        #expect(BluRayMode.suggest(for: [video(10, fps: 24)]).title == "1080p23.976")
        #expect(BluRayMode.suggest(for: [video(10, fps: 25)]).title == "1080i25")
        #expect(BluRayMode.suggest(for: [video(10, fps: 29.97)]).title == "1080i29.97")
        #expect(BluRayMode.suggest(for: [video(10, fps: 30)]).title == "1080i29.97")
        #expect(BluRayMode.suggest(for: [video(10, fps: 50)]).title == "720p50")
        #expect(BluRayMode.suggest(for: [video(10, fps: 60)]).title == "720p59.94")
        #expect(BluRayMode.suggest(for: []).title == "1080p23.976")
    }

    @Test func theMuxerInstructionsJoinTheVideosWithAChapterAtEachStart() {
        let mode = BluRayMode.suggest(for: [video(10)])
        let meta = BluRayAuthoring.metaFile(files: ["title1.mkv", "title2.mkv", "title3.mkv"], seconds: [70, 3_700.4, 20], mode: mode, label: "MY_DISC")
        #expect(meta.contains("--blu-ray"))
        #expect(meta.contains("--custom-chapters=00:00:00.000;00:01:10.000;01:02:50.000"))
        #expect(meta.contains("--label=\"MY_DISC\""))
        #expect(meta.contains("V_MPEG4/ISO/AVC, \"title1.mkv\"+\"title2.mkv\"+\"title3.mkv\", fps=23.976, insertSEI, contSPS, track=1"))
        #expect(meta.contains("A_AC3, \"title1.mkv\"+\"title2.mkv\"+\"title3.mkv\", track=2"))
    }

    @Test func theConvertCommandMakesBluRayLegalVideoAndAC3Sound() {
        let mode = BluRayMode.suggest(for: [video(10, fps: 25)])
        let args = BluRayAuthoring.convertArguments(input: URL(fileURLWithPath: "/in/a.mov"), output: URL(fileURLWithPath: "/w/title1.mkv"), mode: mode, videoKbps: 15_000, hasAudio: false, seconds: 12.5)
        let line = args.joined(separator: " ")
        #expect(line.contains("scale=1920:1080:force_original_aspect_ratio=decrease"))
        #expect(line.contains("-c:v libx264") && line.contains("-level:v 4.1") && line.contains("-b:v 15000k"))
        #expect(line.contains("bluray-compat=1") && line.contains("fake-interlaced=1"))
        #expect(line.contains("anullsrc") && line.contains("-map 1:a:0"))   // a video with no sound gets silence
        #expect(line.contains("-c:a ac3") && line.hasSuffix("-f matroska /w/title1.mkv"))
    }
}
