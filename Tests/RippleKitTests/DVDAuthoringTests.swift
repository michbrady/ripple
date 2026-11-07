import CoreGraphics
import Foundation
import XCTest
@testable import RippleKit

final class DVDAuthoringTests: XCTestCase {
    // MARK: Fitting a picture onto the disc

    func testWidescreenVideoFillsAWidescreenFrame() {
        let g = DVDGeometry.fit(displayAspect: 16.0 / 9, widescreen: true, standard: .ntsc)
        XCTAssertEqual(g.width, 720); XCTAssertEqual(g.height, 480)
        XCTAssertEqual(g.contentWidth, 720); XCTAssertEqual(g.contentHeight, 480)
        XCTAssertEqual(g.padX, 0); XCTAssertEqual(g.padY, 0)
        XCTAssertEqual(g.sar, "32/27"); XCTAssertEqual(g.aspectLabel, "16:9")
    }

    func testAStandardVideoInAWidescreenFrameGetsBarsAtTheSides() {
        let g = DVDGeometry.fit(displayAspect: 4.0 / 3, widescreen: true, standard: .ntsc)
        XCTAssertEqual(g.contentHeight, 480)
        XCTAssertEqual(g.contentWidth, 540)              // 4:3 of a 16:9 picture is 3/4 of its width: 720 * 0.75
        XCTAssertEqual(g.padX, 90); XCTAssertEqual(g.padY, 0)
    }

    func testAWidescreenVideoInAStandardFrameGetsBarsAboveAndBelow() {
        let g = DVDGeometry.fit(displayAspect: 16.0 / 9, widescreen: false, standard: .pal)
        XCTAssertEqual(g.contentWidth, 720)
        XCTAssertEqual(g.contentHeight, 432)             // a 16:9 picture in a 4:3 frame is 3/4 of its height: 576 * 0.75
        XCTAssertEqual(g.padY, 72); XCTAssertEqual(g.padX, 0)
        XCTAssertEqual(g.sar, "16/15")
    }

    func testEverySizeIsEvenAndFitsInsideTheFrame() {
        for aspect in [0.5, 1.0, 4.0 / 3, 1.5, 16.0 / 9, 2.0, 2.39, 3.0] {
            for wide in [true, false] {
                for standard in TVStandard.allCases {
                    let g = DVDGeometry.fit(displayAspect: aspect, widescreen: wide, standard: standard)
                    for v in [g.contentWidth, g.contentHeight, g.padX, g.padY] { XCTAssertEqual(v % 2, 0, "\(aspect) \(wide) \(standard)") }
                    XCTAssertLessThanOrEqual(g.contentWidth + 2 * g.padX, g.width)
                    XCTAssertLessThanOrEqual(g.contentHeight + 2 * g.padY, g.height)
                    XCTAssertGreaterThan(g.contentWidth, 0); XCTAssertGreaterThan(g.contentHeight, 0)
                }
            }
        }
    }

    // MARK: Chapters

    func testChaptersEveryFiveMinutesAndNoneForAShortVideo() {
        XCTAssertEqual(DVDAuthoring.chapterStarts(seconds: 300), [0])
        XCTAssertEqual(DVDAuthoring.chapterStarts(seconds: 599), [0])
        XCTAssertEqual(DVDAuthoring.chapterStarts(seconds: 600), [0, 300])
        XCTAssertEqual(DVDAuthoring.chapterAttribute(seconds: 1_500), "0,5:00,10:00,15:00,20:00")
        XCTAssertEqual(DVDAuthoring.chapterAttribute(seconds: 3_700), "0,5:00,10:00,15:00,20:00,25:00,30:00,35:00,40:00,45:00,50:00,55:00,1:00:00")
        // A last chapter under a minute is folded into the one before.
        XCTAssertEqual(DVDAuthoring.chapterStarts(seconds: 630), [0, 300])
        XCTAssertEqual(DVDAuthoring.chapterStarts(seconds: 661), [0, 300, 600])
    }

    // MARK: Commands

    func testTheConversionCommand() {
        let g = DVDGeometry.fit(displayAspect: 16.0 / 9, widescreen: true, standard: .ntsc)
        let args = DVDAuthoring.convertArguments(input: URL(fileURLWithPath: "/in/a b.mov"), output: URL(fileURLWithPath: "/w/t1.mpg"), geometry: g, standard: .ntsc, videoKbps: 5_200, hasAudio: true)
        let line = args.joined(separator: " ")
        XCTAssertTrue(line.contains("-i /in/a b.mov"))
        XCTAssertTrue(line.contains("-c:v mpeg2video -b:v 5200k -maxrate 9000k -bufsize 1835k"))
        XCTAssertTrue(line.contains("-g 15")); XCTAssertTrue(line.contains("-aspect 16:9"))
        XCTAssertTrue(line.contains("-c:a ac3 -b:a 192k -ar 48000"))
        XCTAssertTrue(line.contains("fps=30000/1001")); XCTAssertTrue(line.contains("setsar=32/27"))
        XCTAssertTrue(line.hasSuffix("-f dvd -muxrate 10080000 -packetsize 2048 /w/t1.mpg"))
        XCTAssertFalse(line.contains("anullsrc"))
        let pal = DVDAuthoring.convertArguments(input: URL(fileURLWithPath: "/in/a.mov"), output: URL(fileURLWithPath: "/w/t.mpg"), geometry: .fit(displayAspect: 1.5, widescreen: false, standard: .pal), standard: .pal, videoKbps: 4_000, hasAudio: false)
        XCTAssertTrue(pal.contains("-g") && pal[pal.firstIndex(of: "-g")! + 1] == "12")
        XCTAssertTrue(pal.joined(separator: " ").contains("anullsrc")); XCTAssertTrue(pal.contains("-shortest"))
        XCTAssertTrue(pal.joined(separator: " ").contains("fps=25"))
    }

    func testProgressLines() {
        XCTAssertEqual(DVDAuthoring.progress(line: "out_time_us=30000000", total: 60) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(DVDAuthoring.progress(line: "out_time_ms=15000000", total: 60) ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(DVDAuthoring.progress(line: "out_time_us=999999999", total: 60), 1)
        XCTAssertNil(DVDAuthoring.progress(line: "frame=100", total: 60))
        XCTAssertNil(DVDAuthoring.progress(line: "out_time_us=N/A", total: 60))
        XCTAssertNil(DVDAuthoring.progress(line: "out_time_us=100", total: 0))
    }

    // MARK: The disc description

    func buttonsPage(_ range: Range<Int>, page: Int, of pages: Int) -> [DVDMenuButton] {
        DVDMenuLayout.buttons(titles: range, page: page, pageCount: pages, standard: .ntsc)
    }

    func testTheDiscDescription() {
        let titles = [DVDTitleSpec(number: 1, name: "One & Two", file: "title1.mpg", seconds: 700), DVDTitleSpec(number: 2, name: "Two", file: "title2.mpg", seconds: 120)]
        let xml = DVDAuthoring.authorXML(standard: .ntsc, widescreen: true, titles: titles,
                                         pages: [buttonsPage(0..<2, page: 0, of: 2), buttonsPage(2..<3, page: 1, of: 2)], menuFiles: ["menu1.mpg", "menu2.mpg"])
        XCTAssertTrue(xml.contains("<fpc>g1 = 0; jump vmgm menu 1;</fpc>"))
        XCTAssertEqual(xml.components(separatedBy: "<pgc entry=\"title\"").count - 1, 1)   // only the first page is the entry
        XCTAssertTrue(xml.contains("<vob file=\"menu1.mpg\" pause=\"inf\" />")); XCTAssertTrue(xml.contains("<vob file=\"menu2.mpg\" pause=\"inf\" />"))
        XCTAssertTrue(xml.contains("g1 = 0; jump title 1;")); XCTAssertTrue(xml.contains("g1 = 1; jump title 1;"))   // title 1 and Play All
        XCTAssertTrue(xml.contains("jump menu 2;"))                      // Next on page 1
        XCTAssertTrue(xml.contains("jump menu 1;"))                      // Previous on page 2
        XCTAssertTrue(xml.contains("aspect=\"16:9\" widescreen=\"nopanscan\""))
        XCTAssertTrue(xml.contains("chapters=\"0,5:00,10:00\""))         // 700 s
        XCTAssertTrue(xml.contains("chapters=\"0\""))                    // 120 s
        XCTAssertTrue(xml.contains("if (g1 eq 1) jump title 2; g1 = 0; call vmgm menu 1;"))   // title 1 carries on in Play All
        XCTAssertFalse(xml.contains("jump title 3"))                     // the last title only returns to the menu
        XCTAssertTrue(xml.hasPrefix("<?xml"))
    }

    func testNamesAreEscapedInTheXML() {
        let titles = [DVDTitleSpec(number: 1, name: "x", file: "a&b <c>.mpg", seconds: 10)]
        let xml = DVDAuthoring.authorXML(standard: .pal, widescreen: false, titles: titles, pages: [buttonsPage(0..<1, page: 0, of: 1)], menuFiles: ["m\"1.mpg"])
        XCTAssertTrue(xml.contains("a&amp;b &lt;c&gt;.mpg")); XCTAssertTrue(xml.contains("m&quot;1.mpg"))
        XCTAssertTrue(xml.contains("format=\"pal\"")); XCTAssertTrue(xml.contains("aspect=\"4:3\" />"))
        // The XML is well formed.
        XCTAssertNotNil(try? XMLDocument(xmlString: xml, options: []))
    }

    func testTheButtonDescriptionForSpumux() throws {
        let buttons = buttonsPage(0..<3, page: 0, of: 1)
        let xml = DVDAuthoring.spumuxXML(standard: .ntsc, buttons: buttons, normal: "n.png", highlight: "h.png", select: "s.png")
        XCTAssertTrue(xml.contains("<subpictures format=\"ntsc\">")); XCTAssertTrue(xml.contains("highlight=\"h.png\" select=\"s.png\""))
        XCTAssertEqual(xml.components(separatedBy: "<button ").count - 1, buttons.count)
        XCTAssertTrue(xml.contains("x0=\"\(buttons[0].x0)\" y0=\"\(buttons[0].y0)\" x1=\"\(buttons[0].x1)\" y1=\"\(buttons[0].y1)\""))
        _ = try XMLDocument(xmlString: xml, options: [])
    }

    // MARK: Looks

    func testEveryLooksTextIsReadable() {
        XCTAssertEqual(MenuLook.allCases.count, 4)
        for look in MenuLook.allCases {
            XCTAssertGreaterThanOrEqual(look.textContrast, 7, "\(look) on its plain background")
            XCTAssertGreaterThanOrEqual(look.worstTextContrastOverPicture, 7, "\(look) over a pure white or pure black picture")
        }
    }

    func testABackgroundPictureCoversTheMenu() throws {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let page = try XCTUnwrap(DVDMenuRenderer.render(discName: "X", titles: [DVDMenuTitle(name: "a")], standard: .ntsc, look: .midnight, background: ctx.makeImage()).first)
        XCTAssertGreaterThan(page.picture.count, 1_000)
        for look in MenuLook.allCases {
            let out = DVDMenuRenderer.render(discName: "X", titles: [DVDMenuTitle(name: "a")], standard: .pal, look: look).first!
            XCTAssertEqual(out.buttons.count, 2)
        }
    }

    // MARK: The real ffmpeg makes real DVD video

    func probe(_ file: URL) async throws -> String {
        let ffmpeg = try XCTUnwrap(DVDTestTools.ffmpeg)
        let r = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-i", file.path])
        return r.error
    }

    func testARealVideoBecomesDVDVideo() async throws {
        let ffmpeg = try XCTUnwrap(DVDTestTools.ffmpeg, "no ffmpeg in .dvdtools")
        let dir = try DVDTestTools.tempFolder()
        let source = dir.appending(path: "in.mp4")
        try await DVDTestTools.makeVideo(source, seconds: 4, size: "1280x720", rate: 24)
        for (standard, wide, expectSize, expectRate, expectDAR) in [(TVStandard.ntsc, true, "720x480", "29.97", "16:9"), (.pal, false, "720x576", "25", "4:3")] {
            let video = try await VideoProbe.read(source, ffmpeg: ffmpeg).get()
            let g = DVDGeometry.fit(displayAspect: video.displayAspect, widescreen: wide, standard: standard)
            let out = dir.appending(path: "out-\(standard.rawValue).mpg")
            let r = try await ProcessRunner.run(ffmpeg, DVDAuthoring.convertArguments(input: source, output: out, geometry: g, standard: standard, videoKbps: 5_000, hasAudio: true))
            XCTAssertEqual(r.status, 0, r.error)
            let report = try await probe(out)
            XCTAssertTrue(report.contains("mpeg2video"), report); XCTAssertTrue(report.contains(expectSize), report)
            XCTAssertTrue(report.contains("DAR \(expectDAR)"), report); XCTAssertTrue(report.contains("\(expectRate) fps"), report)
            XCTAssertTrue(report.contains("ac3") && report.contains("48000 Hz"), report)
            XCTAssertTrue(report.contains("Input #0, mpeg"), report)    // a program stream
        }
    }

    func testAVideoWithNoSoundGetsSilence() async throws {
        let ffmpeg = try XCTUnwrap(DVDTestTools.ffmpeg)
        let dir = try DVDTestTools.tempFolder()
        let source = dir.appending(path: "silent.mov")
        try await DVDTestTools.makeVideo(source, seconds: 3, audio: false)
        let video = try await VideoProbe.read(source, ffmpeg: ffmpeg).get()
        XCTAssertFalse(video.hasAudio)
        let out = dir.appending(path: "out.mpg")
        let r = try await ProcessRunner.run(ffmpeg, DVDAuthoring.convertArguments(input: source, output: out, geometry: .fit(displayAspect: video.displayAspect, widescreen: true, standard: .ntsc), standard: .ntsc, videoKbps: 4_000, hasAudio: false))
        XCTAssertEqual(r.status, 0, r.error)
        let report = try await probe(out)
        XCTAssertTrue(report.contains("ac3"), report)
        let seconds = try XCTUnwrap(VideoProbe.seconds(in: report)); XCTAssertEqual(seconds, 3, accuracy: 0.4)
    }

    func testAMenuPictureAndMusicBecomeAMenuVideo() async throws {
        let ffmpeg = try XCTUnwrap(DVDTestTools.ffmpeg)
        let dir = try DVDTestTools.tempFolder()
        let page = try XCTUnwrap(DVDMenuRenderer.render(discName: "Test", titles: [DVDMenuTitle(name: "One")], standard: .ntsc).first)
        let picture = dir.appending(path: "menu.png"); try page.picture.write(to: picture)
        let music = dir.appending(path: "music.wav")
        let tone = try await ProcessRunner.run(ffmpeg, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=330:duration=2", music.path])
        XCTAssertEqual(tone.status, 0)
        for (withMusic, name) in [(true, "a.mpg"), (false, "b.mpg")] {
            let out = dir.appending(path: name)
            let r = try await ProcessRunner.run(ffmpeg, DVDAuthoring.menuVideoArguments(picture: picture, music: withMusic ? music : nil, seconds: 5, standard: .ntsc, output: out))
            XCTAssertEqual(r.status, 0, r.error)
            let report = try await probe(out)
            XCTAssertTrue(report.contains("720x480") && report.contains("DAR 4:3") && report.contains("ac3"), report)
            XCTAssertEqual(try XCTUnwrap(VideoProbe.seconds(in: report)), 5, accuracy: 0.5, report)
        }
    }

    func testAThumbnailIsMadeFromAVideo() async throws {
        let ffmpeg = try XCTUnwrap(DVDTestTools.ffmpeg)
        let dir = try DVDTestTools.tempFolder()
        let source = dir.appending(path: "a.mp4"); try await DVDTestTools.makeVideo(source, seconds: 4)
        let thumb = dir.appending(path: "t.png")
        let r = try await ProcessRunner.run(ffmpeg, DVDAuthoring.thumbnailArguments(input: source, output: thumb, at: 1))
        XCTAssertEqual(r.status, 0, r.error)
        let report = try await probe(thumb)
        XCTAssertTrue(report.contains("320x180"), report)
    }
}
