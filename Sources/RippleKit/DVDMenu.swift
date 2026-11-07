import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a button on the menu does.
public enum DVDMenuAction: Equatable, Sendable {
    case playAll
    /// 1-based title number.
    case title(Int)
    case previous
    case next
}

/// One button: where it is on the 720-wide menu picture, what it does, and which button the arrow keys reach.
public struct DVDMenuButton: Equatable, Sendable {
    public var name: String
    /// Inclusive pixel corners. Left and top are even, right and bottom are odd, as spumux wants.
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public var action: DVDMenuAction
    public var up = "", down = "", left = "", right = ""

    public var centerX: Double { Double(x0 + x1) / 2 }
    public var centerY: Double { Double(y0 + y1) / 2 }
}

/// One drawn page: the picture, the two button overlays (four colors each, no smoothing), and the buttons.
public struct DVDMenuPage: Sendable {
    public var picture: Data
    public var highlight: Data
    public var select: Data
    public var buttons: [DVDMenuButton]
}

public struct DVDMenuTitle: @unchecked Sendable {
    public var name: String
    public var thumbnail: CGImage?
    public init(name: String, thumbnail: CGImage? = nil) { self.name = name; self.thumbnail = thumbnail }
}

public enum DVDMenuLayout {
    public static let perPage = 6
    static let columns = 3

    /// Which titles (0-based) go on each page.
    public static func pages(titleCount: Int, perPage: Int = DVDMenuLayout.perPage) -> [Range<Int>] {
        guard titleCount > 0 else { return [0..<0] }
        return stride(from: 0, to: titleCount, by: perPage).map { $0..<min($0 + perPage, titleCount) }
    }

    /// Where each button goes on a page of this TV standard. Safe margins keep everything inside what every TV shows.
    public static func buttons(titles: Range<Int>, page: Int, pageCount: Int, standard: TVStandard) -> [DVDMenuButton] {
        let h = standard.height
        let scale = Double(h) / 480
        func even(_ v: Double) -> Int { Int(v.rounded()) / 2 * 2 }
        var buttons: [DVDMenuButton] = []
        let cellW = 160, cellH = even(128 * scale), gapX = 48, left = 48
        let rowTop = [even(112 * scale), even(112 * scale) + cellH + even(12 * scale)]
        for (i, title) in titles.enumerated() {
            let col = i % columns, row = i / columns
            let x = left + col * (cellW + gapX), y = rowTop[row]
            buttons.append(DVDMenuButton(name: "b\(buttons.count + 1)", x0: x, y0: y, x1: x + cellW - 1, y1: y + cellH - 1, action: .title(title + 1)))
        }
        let controlsY = even(404 * scale), controlsH = even(40 * scale)
        buttons.append(DVDMenuButton(name: "b\(buttons.count + 1)", x0: 48, y0: controlsY, x1: 48 + 180 - 1, y1: controlsY + controlsH - 1, action: .playAll))
        if page > 0 {
            buttons.append(DVDMenuButton(name: "b\(buttons.count + 1)", x0: 330, y0: controlsY, x1: 330 + 150 - 1, y1: controlsY + controlsH - 1, action: .previous))
        }
        if page < pageCount - 1 {
            buttons.append(DVDMenuButton(name: "b\(buttons.count + 1)", x0: 522, y0: controlsY, x1: 522 + 150 - 1, y1: controlsY + controlsH - 1, action: .next))
        }
        return linkArrows(buttons)
    }

    /// Sets up, down, left, and right for every button: the nearest button in that direction, or itself when there is none.
    public static func linkArrows(_ buttons: [DVDMenuButton]) -> [DVDMenuButton] {
        var result = buttons
        for i in result.indices {
            let me = result[i]
            func nearest(_ allowed: (DVDMenuButton) -> Bool, along: (DVDMenuButton) -> Double, across: (DVDMenuButton) -> Double) -> String {
                let best = result.enumerated().filter { $0.offset != i && allowed($0.element) }
                    .min { along($0.element) + 3 * across($0.element) < along($1.element) + 3 * across($1.element) }
                return best?.element.name ?? me.name
            }
            result[i].up = nearest({ $0.centerY < me.centerY - 1 }, along: { me.centerY - $0.centerY }, across: { abs($0.centerX - me.centerX) })
            result[i].down = nearest({ $0.centerY > me.centerY + 1 }, along: { $0.centerY - me.centerY }, across: { abs($0.centerX - me.centerX) })
            result[i].left = nearest({ $0.centerX < me.centerX - 1 && abs($0.centerY - me.centerY) < 30 }, along: { me.centerX - $0.centerX }, across: { abs($0.centerY - me.centerY) })
            result[i].right = nearest({ $0.centerX > me.centerX + 1 && abs($0.centerY - me.centerY) < 30 }, along: { $0.centerX - me.centerX }, across: { abs($0.centerY - me.centerY) })
        }
        return result
    }
}

/// One of the four built-in looks for a menu.
public enum MenuLook: String, CaseIterable, Identifiable, Sendable {
    case classic, midnight, daylight, warm

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public typealias RGB = (r: Double, g: Double, b: Double)
    /// Top and bottom of the background gradient.
    var gradient: (top: RGB, bottom: RGB) {
        switch self {
        case .classic: ((0.07, 0.30, 0.38), (0.02, 0.12, 0.17))
        case .midnight: ((0.05, 0.06, 0.16), (0.0, 0.0, 0.03))
        case .daylight: ((0.96, 0.97, 0.99), (0.84, 0.88, 0.93))
        case .warm: ((0.30, 0.12, 0.05), (0.12, 0.04, 0.02))
        }
    }
    var text: RGB { self == .daylight ? (0.07, 0.07, 0.09) : (1, 1, 1) }
    /// A picture behind the menu is covered by this layer so the text stays readable: black for dark looks, white for light.
    var coverIsLight: Bool { self == .daylight }
    /// The frame around the chosen button, and the frame while it is pressed. They must stand out against the background.
    var highlight: (r: UInt8, g: UInt8, b: UInt8) { self == .daylight ? (200, 30, 30) : (255, 214, 10) }
    var select: (r: UInt8, g: UInt8, b: UInt8) { self == .daylight ? (0, 90, 200) : (255, 255, 255) }
    static let coverOpacity = 0.7

    /// WCAG contrast ratio between two colors, 1 to 21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        func luminance(_ c: RGB) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// The worst contrast between this look's text and a background picture of any color, once the cover layer is on.
    public var worstTextContrastOverPicture: Double {
        let blend: (RGB) -> RGB = { c in
            let cover: Double = self.coverIsLight ? 1 : 0
            let a = Self.coverOpacity
            return (c.r * (1 - a) + cover * a, c.g * (1 - a) + cover * a, c.b * (1 - a) + cover * a)
        }
        // The hardest pictures are pure white and pure black.
        return [(1.0, 1.0, 1.0), (0.0, 0.0, 0.0)].map { Self.contrast(text, blend(($0.0, $0.1, $0.2))) }.min()!
    }

    /// The worst contrast between the text and the plain gradient.
    public var textContrast: Double {
        min(Self.contrast(text, gradient.top), Self.contrast(text, gradient.bottom))
    }
}

public enum DVDMenuRenderer {
    /// `background` is the user's own picture; it is cropped to fill the menu and covered so the text stays readable.
    public static func render(discName: String, titles: [DVDMenuTitle], standard: TVStandard, look: MenuLook = .classic, background: CGImage? = nil) -> [DVDMenuPage] {
        let pages = DVDMenuLayout.pages(titleCount: titles.count)
        return pages.enumerated().map { index, range in
            let buttons = DVDMenuLayout.buttons(titles: range, page: index, pageCount: pages.count, standard: standard)
            return DVDMenuPage(
                picture: png(picture(discName: discName, titles: titles, buttons: buttons, page: index, pages: pages.count, standard: standard, look: look, background: background)),
                highlight: png(overlay(buttons: buttons, color: look.highlight, grow: 4, standard: standard)),
                select: png(overlay(buttons: buttons, color: look.select, grow: 4, standard: standard)),
                buttons: buttons)
        }
    }

    // MARK: Drawing

    static func context(_ standard: TVStandard) -> CGContext {
        let ctx = CGContext(data: nil, width: standard.width, height: standard.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Count y from the top, the way the buttons do.
        ctx.translateBy(x: 0, y: CGFloat(standard.height)); ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    static func picture(discName: String, titles: [DVDMenuTitle], buttons: [DVDMenuButton], page: Int, pages: Int, standard: TVStandard, look: MenuLook, background: CGImage?) -> CGImage {
        let ctx = context(standard)
        let w = CGFloat(standard.width), h = CGFloat(standard.height)
        let g = look.gradient
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: g.top.r, green: g.top.g, blue: g.top.b, alpha: 1), CGColor(red: g.bottom.r, green: g.bottom.g, blue: g.bottom.b, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        if let background {
            // Crop to fill, then cover: a picture of any color keeps the text readable (see `MenuLook.worstTextContrastOverPicture`).
            let scale = max(w / CGFloat(background.width), h / CGFloat(background.height))
            let size = CGSize(width: CGFloat(background.width) * scale, height: CGFloat(background.height) * scale)
            ctx.saveGState(); ctx.interpolationQuality = .high
            ctx.translateBy(x: (w - size.width) / 2, y: (h + size.height) / 2); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(background, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
            let cover: CGFloat = look.coverIsLight ? 1 : 0
            ctx.setFillColor(CGColor(red: cover, green: cover, blue: cover, alpha: MenuLook.coverOpacity)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        text(ctx, discName, size: 30, bold: true, in: CGRect(x: 48, y: 44 * h / 480, width: w - 96, height: 44), align: .center, standard: standard, color: look.text)
        if pages > 1 {
            text(ctx, "Page \(page + 1) of \(pages)", size: 14, bold: false, in: CGRect(x: 48, y: 84 * h / 480, width: w - 96, height: 20), align: .center, standard: standard, color: look.text)
        }
        for button in buttons {
            let rect = CGRect(x: button.x0, y: button.y0, width: button.x1 - button.x0 + 1, height: button.y1 - button.y0 + 1)
            switch button.action {
            case .title(let number):
                let title = titles[number - 1]
                let thumb = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.width * 9 / 16)
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(thumb)
                if let image = title.thumbnail { draw(image, fitting: thumb, in: ctx) }
                text(ctx, title.name, size: 12, bold: false, in: CGRect(x: rect.minX, y: thumb.maxY + 4, width: rect.width, height: rect.maxY - thumb.maxY - 4), align: .center, standard: standard, lines: 2, color: look.text)
            case .playAll: label(ctx, "Play All", rect, standard, look)
            case .previous: label(ctx, "Previous", rect, standard, look)
            case .next: label(ctx, "Next", rect, standard, look)
            }
        }
        return ctx.makeImage()!
    }

    static func label(_ ctx: CGContext, _ string: String, _ rect: CGRect, _ standard: TVStandard, _ look: MenuLook) {
        let tone: CGFloat = look.coverIsLight ? 0 : 1
        ctx.setFillColor(CGColor(red: tone, green: tone, blue: tone, alpha: 0.16))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
        text(ctx, string, size: 18, bold: true, in: rect.insetBy(dx: 0, dy: 9 * CGFloat(standard.height) / 480), align: .center, standard: standard, color: look.text)
    }

    static func draw(_ image: CGImage, fitting box: CGRect, in ctx: CGContext) {
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        ctx.saveGState(); ctx.interpolationQuality = .high
        // The context is flipped; draw the picture upright.
        ctx.translateBy(x: target.minX, y: target.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    enum Align { case center }

    static func text(_ ctx: CGContext, _ string: String, size: CGFloat, bold: Bool, in rect: CGRect, align: Align, standard: TVStandard, lines: Int = 1, color: MenuLook.RGB = (1, 1, 1)) {
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
        let paragraph = NSMutableParagraphStyleBox.centered(wrapping: lines > 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        // CoreText draws upward from the bottom-left; flip back around the rectangle.
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        ctx.restoreGState()
    }

    /// A frame around every button, in one flat color with no smoothing: the highlight or the pressed look.
    static func overlay(buttons: [DVDMenuButton], color: (r: UInt8, g: UInt8, b: UInt8), grow: Int, standard: TVStandard) -> CGImage {
        let ctx = context(standard)
        ctx.setShouldAntialias(false); ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1))
        for b in buttons {
            let x0 = b.x0 - grow, y0 = b.y0 - grow, x1 = b.x1 + 1 + grow, y1 = b.y1 + 1 + grow
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: grow))                 // top
            ctx.fill(CGRect(x: x0, y: y1 - grow, width: x1 - x0, height: grow))          // bottom
            ctx.fill(CGRect(x: x0, y: y0, width: grow, height: y1 - y0))                 // left
            ctx.fill(CGRect(x: x1 - grow, y: y0, width: grow, height: y1 - y0))          // right
        }
        return ctx.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// A centered paragraph style for CoreText.
enum NSMutableParagraphStyleBox {
    static func centered(wrapping: Bool) -> CTParagraphStyle {
        var alignment = CTTextAlignment.center
        var lineBreak = wrapping ? CTLineBreakMode.byWordWrapping : CTLineBreakMode.byTruncatingTail
        return withUnsafePointer(to: &alignment) { a in
            withUnsafePointer(to: &lineBreak) { b in
                CTParagraphStyleCreate([
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: b),
                ], 2)
            }
        }
    }
}
