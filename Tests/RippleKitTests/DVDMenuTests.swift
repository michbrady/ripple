import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import RippleKit

final class DVDMenuTests: XCTestCase {
    func testTitlesFillPagesOfSix() {
        XCTAssertEqual(DVDMenuLayout.pages(titleCount: 0), [0..<0])
        XCTAssertEqual(DVDMenuLayout.pages(titleCount: 1), [0..<1])
        XCTAssertEqual(DVDMenuLayout.pages(titleCount: 6), [0..<6])
        XCTAssertEqual(DVDMenuLayout.pages(titleCount: 7), [0..<6, 6..<7])
        XCTAssertEqual(DVDMenuLayout.pages(titleCount: 13).count, 3)
    }

    func testEveryPageHasTitleButtonsPlayAllAndTheRightArrows() {
        let first = DVDMenuLayout.buttons(titles: 0..<6, page: 0, pageCount: 3, standard: .ntsc).map(\.action)
        XCTAssertEqual(first, (1...6).map { .title($0) } + [.playAll, .next])
        let middle = DVDMenuLayout.buttons(titles: 6..<12, page: 1, pageCount: 3, standard: .ntsc).map(\.action)
        XCTAssertEqual(middle, (7...12).map { .title($0) } + [.playAll, .previous, .next])
        let last = DVDMenuLayout.buttons(titles: 12..<13, page: 2, pageCount: 3, standard: .ntsc).map(\.action)
        XCTAssertEqual(last, [.title(13), .playAll, .previous])
        XCTAssertEqual(DVDMenuLayout.buttons(titles: 0..<0, page: 0, pageCount: 1, standard: .ntsc).map(\.action), [.playAll])
    }

    func testButtonsStayInsideTheSafeAreaAndOnEvenPixels() {
        for standard in TVStandard.allCases {
            for (page, range) in DVDMenuLayout.pages(titleCount: 20).enumerated() {
                for b in DVDMenuLayout.buttons(titles: range, page: page, pageCount: 4, standard: standard) {
                    XCTAssertEqual(b.x0 % 2, 0, b.name); XCTAssertEqual(b.y0 % 2, 0, b.name)
                    XCTAssertEqual(b.x1 % 2, 1, b.name); XCTAssertEqual(b.y1 % 2, 1, b.name)
                    // 5 percent of the width and height are cut off by many TVs, and the highlight frame grows 4 pixels.
                    XCTAssertGreaterThanOrEqual(b.x0 - 4, 36, b.name); XCTAssertLessThanOrEqual(b.x1 + 4, standard.width - 36, b.name)
                    XCTAssertGreaterThanOrEqual(b.y0 - 4, Int(Double(standard.height) * 0.05), b.name)
                    XCTAssertLessThanOrEqual(b.y1 + 4, Int(Double(standard.height) * 0.95), b.name)
                }
            }
        }
    }

    func testNoTwoButtonsOverlapAndNamesAreUnique() {
        let buttons = DVDMenuLayout.buttons(titles: 0..<6, page: 1, pageCount: 3, standard: .pal)
        XCTAssertEqual(Set(buttons.map(\.name)).count, buttons.count)
        for (i, a) in buttons.enumerated() {
            for b in buttons[(i + 1)...] {
                let apart = a.x1 + 8 < b.x0 || b.x1 + 8 < a.x0 || a.y1 + 8 < b.y0 || b.y1 + 8 < a.y0
                XCTAssertTrue(apart, "\(a.name) and \(b.name) touch")
            }
        }
    }

    func testArrowKeysReachEveryButton() {
        let buttons = DVDMenuLayout.buttons(titles: 0..<6, page: 1, pageCount: 3, standard: .ntsc)
        let byName = Dictionary(uniqueKeysWithValues: buttons.map { ($0.name, $0) })
        // First row: title 1 sits left of title 2; title 4 is below title 1.
        XCTAssertEqual(byName["b1"]?.right, "b2"); XCTAssertEqual(byName["b2"]?.left, "b1")
        XCTAssertEqual(byName["b1"]?.down, "b4"); XCTAssertEqual(byName["b4"]?.up, "b1")
        XCTAssertEqual(byName["b1"]?.up, "b1"); XCTAssertEqual(byName["b1"]?.left, "b1")   // nothing there: stay
        // Every button can be reached from the first one by following arrows.
        var seen: Set<String> = ["b1"], queue = ["b1"]
        while let name = queue.popLast() {
            let b = byName[name]!
            for next in [b.up, b.down, b.left, b.right] where seen.insert(next).inserted { queue.append(next) }
        }
        XCTAssertEqual(seen, Set(buttons.map(\.name)))
    }

    // MARK: Drawing

    func image(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Every distinct pixel value in the picture, as RGBA.
    func colors(_ image: CGImage) -> Set<UInt32> {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var set: Set<UInt32> = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            set.insert(UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16 | UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3]))
        }
        return set
    }

    func titles(_ n: Int) -> [DVDMenuTitle] { (1...max(1, n)).map { DVDMenuTitle(name: "Title number \($0) with a fairly long name to wrap") } }

    func testPicturesHaveTheRightSizeForEachStandard() throws {
        for standard in TVStandard.allCases {
            let page = try XCTUnwrap(DVDMenuRenderer.render(discName: "Summer 2024", titles: titles(3), standard: standard).first)
            for data in [page.picture, page.highlight, page.select] {
                let picture = try image(data)
                XCTAssertEqual(picture.width, 720); XCTAssertEqual(picture.height, standard.height)
            }
        }
    }

    func testTheButtonOverlaysUseOnlyFlatColorsWithNoSmoothing() throws {
        let page = try XCTUnwrap(DVDMenuRenderer.render(discName: "Disc", titles: titles(6), standard: .ntsc).first)
        for data in [page.highlight, page.select] {
            let found = colors(try image(data))
            XCTAssertLessThanOrEqual(found.count, 2, "a transparent color and one frame color")
            XCTAssertTrue(found.contains(0))   // fully transparent
        }
    }

    func testTheOverlayFramesSitJustOutsideTheButtons() throws {
        let page = try XCTUnwrap(DVDMenuRenderer.render(discName: "Disc", titles: titles(1), standard: .ntsc).first)
        let overlay = try image(page.highlight)
        let b = try XCTUnwrap(page.buttons.first)
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(overlay, in: CGRect(x: -x, y: -(overlay.height - 1 - y), width: overlay.width, height: overlay.height))
            return px[3]
        }
        XCTAssertEqual(alpha(b.x0 - 2, b.y0 + 10), 255)            // on the frame
        XCTAssertEqual(alpha((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2), 0)   // inside the button: clear
        XCTAssertEqual(alpha(b.x0 - 12, b.y0 + 10), 0)             // well outside: clear
    }

    func testPagesAreDrawnForManyTitles() {
        let pages = DVDMenuRenderer.render(discName: "Disc", titles: titles(14), standard: .ntsc)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[2].buttons.map(\.action), [.title(13), .title(14), .playAll, .previous])
    }

    /// Writes a sample page to /tmp so a person can look at it.
    func testWriteASamplePageToLookAt() throws {
        let page = try XCTUnwrap(DVDMenuRenderer.render(discName: "Summer Trip 2024", titles: titles(6) + [DVDMenuTitle(name: "Seventh")], standard: .ntsc).first)
        try page.picture.write(to: URL(fileURLWithPath: "/tmp/ripple-menu-sample.png"))
        try page.highlight.write(to: URL(fileURLWithPath: "/tmp/ripple-menu-sample-highlight.png"))
    }
}

final class DVDSceneMenuTests: XCTestCase {
    func title(_ minutes: Double) -> DVDMenuTitle { DVDMenuTitle(name: "T", seconds: minutes * 60) }

    func testOnlyLongTitlesGetScenePages() {
        let pages = DVDMenuLayout.scenePages(for: [title(5), title(25), title(9.9), title(40)])
        XCTAssertEqual(pages.map(\.title), [1, 3, 3])           // 25 min: one page of 5 chapters; 40 min: 8 chapters, two pages
        XCTAssertEqual(pages.map(\.chapters), [0..<5, 0..<6, 6..<8])
        XCTAssertEqual(DVDMenuLayout.scenePages(for: [title(5), title(9)]).count, 0)
    }

    func testSceneButtonsLinkChaptersAndMoveBetweenPages() {
        let first = DVDMenuLayout.sceneButtons(title: 2, chapters: 0..<6, sceneIndex: 0, sceneCount: 2, standard: .ntsc)
        XCTAssertEqual(first.map(\.action).prefix(2), [.chapter(title: 3, chapter: 1), .chapter(title: 3, chapter: 2)])
        XCTAssertTrue(first.contains { $0.action == .mainMenu })
        XCTAssertTrue(first.contains { $0.action == .next }); XCTAssertFalse(first.contains { $0.action == .previous })
        let last = DVDMenuLayout.sceneButtons(title: 2, chapters: 6..<8, sceneIndex: 1, sceneCount: 2, standard: .pal)
        XCTAssertTrue(last.contains { $0.action == .previous }); XCTAssertFalse(last.contains { $0.action == .next })
        for button in first + last { XCTAssertTrue(button.x0 >= 48 && button.x1 <= 720 - 48 && button.y1 < 576) }
    }

    func testMainPagesGetAScenesButtonOnlyWhenThereAreScenes() {
        XCTAssertFalse(DVDMenuLayout.buttons(titles: 0..<2, page: 0, pageCount: 1, standard: .ntsc).contains { $0.action == .scenes })
        XCTAssertTrue(DVDMenuLayout.buttons(titles: 0..<2, page: 0, pageCount: 1, standard: .ntsc, hasScenes: true).contains { $0.action == .scenes })
    }

    func testTheRendererDrawsMainThenScenePagesAtTheRightSize() {
        let pages = DVDMenuRenderer.render(discName: "Disc", titles: [title(5), title(40)], standard: .ntsc)
        XCTAssertEqual(pages.map(\.kind), [.main, .scenes, .scenes])
        XCTAssertTrue(pages[0].buttons.contains { $0.action == .scenes })
        XCTAssertEqual(DVDMenuRenderer.render(discName: "Disc", titles: [title(5)], standard: .ntsc).map(\.kind), [.main])
    }

    func testTheDiscDescriptionPutsScenesInTheTitlesetMenus() {
        let titles = [title(40)]
        let rendered = DVDMenuRenderer.render(discName: "Disc", titles: titles, standard: .ntsc)
        let main = rendered.filter { $0.kind == .main }, scenes = rendered.filter { $0.kind == .scenes }
        let xml = DVDAuthoring.authorXML(standard: .ntsc, widescreen: true, titles: [DVDTitleSpec(number: 1, name: "T", file: "titles/title1.mpg", seconds: 2_400)],
                                         pages: main.map(\.buttons), menuFiles: ["menu/menu1.mpg"],
                                         scenePages: scenes.map(\.buttons), sceneMenuFiles: ["menu/menu2.mpg", "menu/menu3.mpg"])
        XCTAssertTrue(xml.contains("jump titleset 1 menu entry ptt;"))          // the Scenes button on the main menu
        XCTAssertEqual(xml.components(separatedBy: "<pgc entry=\"ptt\"").count - 1, 1)
        XCTAssertTrue(xml.contains("g1 = 0; g2 = 1; jump title 1 chapter 1;"))
        XCTAssertTrue(xml.contains("jump vmgm menu 1;"))                         // Main Menu on a scene page
        XCTAssertTrue(xml.contains("if (g2 eq 1) { g2 = 0; call menu entry ptt; }"))
        let withoutScenes = DVDAuthoring.authorXML(standard: .ntsc, widescreen: true, titles: [DVDTitleSpec(number: 1, name: "T", file: "t.mpg", seconds: 60)],
                                                   pages: main.map(\.buttons), menuFiles: ["menu/menu1.mpg"])
        XCTAssertFalse(withoutScenes.contains("entry=\"ptt\"")); XCTAssertFalse(withoutScenes.contains("call menu entry"))
    }
}
