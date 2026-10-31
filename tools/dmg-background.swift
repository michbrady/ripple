// Draws the picture behind the icons in the installer window: Ripple's teal, an arrow, and a line of words.
// Usage: swiftc tools/dmg-background.swift -o /tmp/dmg-background && /tmp/dmg-background out-1x.png out-2x.png
import AppKit

let size = NSSize(width: 600, height: 400)

func render(scale: CGFloat, to path: String) {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap") }
    rep.size = size // 72 dpi at 1x; the 2x file is the same size in points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: scale, y: scale)

    // Ripple's teal, light at the top.
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.69, blue: 0.81, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.54, blue: 0.66, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // The arrow, between the two icons (their centers are 200 points from the top).
    let white = NSColor(white: 1, alpha: 0.92)
    white.setFill()
    let arrow = NSBezierPath()
    let y: CGFloat = 200
    arrow.move(to: NSPoint(x: 236, y: y + 9))
    arrow.line(to: NSPoint(x: 330, y: y + 9))
    arrow.line(to: NSPoint(x: 330, y: y + 28))
    arrow.line(to: NSPoint(x: 366, y: y))
    arrow.line(to: NSPoint(x: 330, y: y - 28))
    arrow.line(to: NSPoint(x: 330, y: y - 9))
    arrow.line(to: NSPoint(x: 236, y: y - 9))
    arrow.close()
    arrow.fill()

    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerY: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: paragraph,
        ]
        let height = size * 1.4
        (string as NSString).draw(in: NSRect(x: 0, y: centerY - height / 2, width: size == 0 ? 0 : 600, height: height), withAttributes: attributes)
    }
    text("Drag Ripple to the Applications folder", size: 24, weight: .semibold, alpha: 0.98, centerY: 340)
    text("Then open it from Applications.", size: 14, weight: .regular, alpha: 0.85, centerY: 52)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
