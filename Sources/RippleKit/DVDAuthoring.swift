import Foundation

/// How a video is fitted onto the disc's picture: the frame, the bars around it, and the pixel shape.
public struct DVDGeometry: Equatable, Sendable {
    public var width: Int, height: Int
    /// The scaled video inside the frame.
    public var contentWidth: Int, contentHeight: Int
    public var padX: Int, padY: Int
    /// The pixel aspect ratio as a fraction ffmpeg understands, such as "32/27".
    public var sar: String
    public var aspectLabel: String

    /// `displayAspect` is the source's width over height as shown. `widescreen` picks the disc's 16:9 or 4:3 frame.
    public static func fit(displayAspect: Double, widescreen: Bool, standard: TVStandard) -> DVDGeometry {
        let frameAspect = widescreen ? 16.0 / 9 : 4.0 / 3
        let w = standard.width, h = standard.height
        // How wide one pixel shows, compared with its height, so that the whole frame has the frame's shape.
        let pixelAspect = frameAspect * Double(h) / Double(w)
        var cw = Double(w), ch = Double(w) * pixelAspect / displayAspect
        if ch > Double(h) { ch = Double(h); cw = Double(h) * displayAspect / pixelAspect }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let contentW = min(w, even(cw)), contentH = min(h, even(ch))
        let sar: String = switch (standard, widescreen) {
        case (.ntsc, true): "32/27"
        case (.ntsc, false): "8/9"
        case (.pal, true): "64/45"
        case (.pal, false): "16/15"
        }
        return DVDGeometry(width: w, height: h, contentWidth: contentW, contentHeight: contentH,
                           padX: (w - contentW) / 2 / 2 * 2, padY: (h - contentH) / 2 / 2 * 2, sar: sar, aspectLabel: widescreen ? "16:9" : "4:3")
    }
}

/// One title as the authoring step needs it.
public struct DVDTitleSpec: Equatable, Sendable {
    public var number: Int
    public var name: String
    /// The converted MPEG-2 file, relative to the work folder.
    public var file: String
    public var seconds: Double
    public init(number: Int, name: String, file: String, seconds: Double) {
        self.number = number; self.name = name; self.file = file; self.seconds = seconds
    }
}

public enum DVDAuthoring {
    public static let chapterSeconds = 300.0
    /// A video must be at least this long before it gets chapters.
    public static let chapterMinimum = 600.0

    /// Chapter starts in seconds: every 5 minutes, and none at all for a short video.
    public static func chapterStarts(seconds: Double) -> [Double] {
        guard seconds >= chapterMinimum else { return [0] }
        var starts: [Double] = [0]
        var t = chapterSeconds
        // A last chapter shorter than a minute would be a useless button; fold it into the one before.
        while t < seconds - 60 { starts.append(t); t += chapterSeconds }
        return starts
    }

    /// "0,5:00,10:00" as dvdauthor writes chapters.
    public static func chapterAttribute(seconds: Double) -> String {
        chapterStarts(seconds: seconds).map { start in
            if start == 0 { return "0" }
            let total = Int(start)
            let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }.joined(separator: ",")
    }

    // MARK: ffmpeg commands

    /// Converts one video to a DVD program stream. The picture is fitted without stretching, the sound becomes AC-3,
    /// and a video with no sound gets silence, since every title on a disc needs the same kind of audio.
    public static func convertArguments(input: URL, output: URL, geometry g: DVDGeometry, standard: TVStandard, videoKbps: Int, hasAudio: Bool) -> [String] {
        let filter = "scale=\(g.contentWidth):\(g.contentHeight):flags=lanczos,pad=\(g.width):\(g.height):\(g.padX):\(g.padY):black,setsar=\(g.sar),fps=\(standard.frameRate),format=yuv420p"
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-i", input.path]
        if !hasAudio { args += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"] }
        args += ["-map", "0:v:0", "-map", hasAudio ? "0:a:0" : "1:a:0", "-vf", filter,
                 "-c:v", "mpeg2video", "-b:v", "\(videoKbps)k", "-maxrate", "\(DVDPlan.maxVideoKbps)k", "-bufsize", "1835k",
                 "-g", standard == .ntsc ? "15" : "12", "-bf", "2", "-aspect", g.aspectLabel,
                 "-c:a", "ac3", "-b:a", "\(DVDPlan.audioKbps)k", "-ar", "48000", "-ac", "2"]
        if !hasAudio { args += ["-shortest"] }
        args += ["-f", "dvd", "-muxrate", "10080000", "-packetsize", "2048", output.path]
        return args
    }

    /// One still picture from a video, for the menu button. `at` is where to look, in seconds.
    public static func thumbnailArguments(input: URL, output: URL, at: Double) -> [String] {
        ["-y", "-hide_banner", "-loglevel", "error", "-ss", String(format: "%.2f", at), "-i", input.path, "-frames:v", "1",
         "-vf", "scale=320:-2:flags=lanczos", output.path]
    }

    /// A menu page picture and music turned into a short video the disc can loop. 4:3, with sound (silence when no music).
    public static func menuVideoArguments(picture: URL, music: URL?, seconds: Int, standard: TVStandard, output: URL) -> [String] {
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", standard.frameRate, "-t", "\(seconds)", "-i", picture.path]
        if let music { args += ["-stream_loop", "-1", "-i", music.path] } else { args += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"] }
        args += ["-map", "0:v:0", "-map", "1:a:0", "-t", "\(seconds)",
                 "-vf", "scale=\(standard.width):\(standard.height),setsar=\(standard == .ntsc ? "8/9" : "16/15"),format=yuv420p",
                 "-c:v", "mpeg2video", "-b:v", "4000k", "-g", standard == .ntsc ? "15" : "12", "-aspect", "4:3", "-r", standard.frameRate,
                 "-c:a", "ac3", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                 "-f", "dvd", "-muxrate", "10080000", "-packetsize", "2048", output.path]
        return args
    }

    /// Reads the "-progress" lines ffmpeg prints, and says how far through `total` seconds it is (0 to 1).
    public static func progress(line: String, total: Double) -> Double? {
        guard total > 0 else { return nil }
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard let micro = Double(line.dropFirst(key.count)), micro >= 0 else { return nil }
            return min(1, micro / 1_000_000 / total)
        }
        return nil
    }

    // MARK: dvdauthor and spumux descriptions

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The command a menu button runs. (From the menu, dvdauthor accepts `jump title N` and refuses `jump titleset 1 title N`; checked with the real program.) `g1` remembers whether Play All is on, so each title knows whether to carry on to the next.
    static func command(for action: DVDMenuAction, page: Int) -> String {
        switch action {
        case .title(let n): "g1 = 0; g2 = 0; jump title \(n);"
        case .playAll: "g1 = 1; g2 = 0; jump title 1;"
        case .next: "jump menu \(page + 2);"
        case .previous: "jump menu \(page);"
        // `g2 = 1` remembers that a scene page started the video, so it ends back at the scenes. The first scene page is the titleset's
        // "ptt" entry. From a titleset menu only `jump` works; from the main menu only `jump title N` and `jump titleset 1 menu entry ptt` do
        // (all checked with the real dvdauthor).
        case .scenes: "jump titleset 1 menu entry ptt;"
        case .chapter(let title, let chapter): "g1 = 0; g2 = 1; jump title \(title) chapter \(chapter);"
        case .mainMenu: "jump vmgm menu 1;"
        }
    }

    /// The whole disc: a menu page per `menuFiles` entry, and every title in one titleset.
    /// `scenePages` are the chapter pages. They live in the titleset's own menus, because the main menu cannot jump to a chapter.
    public static func authorXML(standard: TVStandard, widescreen: Bool, titles: [DVDTitleSpec], pages: [[DVDMenuButton]], menuFiles: [String],
                                 scenePages: [[DVDMenuButton]] = [], sceneMenuFiles: [String] = []) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<dvdauthor>\n  <vmgm>\n    <fpc>g1 = 0; jump vmgm menu 1;</fpc>\n    <menus>\n"
        xml += "      <video format=\"\(standard.format)\" aspect=\"4:3\" />\n      <audio format=\"ac3\" lang=\"en\" />\n"
        for (index, buttons) in pages.enumerated() {
            xml += "      <pgc\(index == 0 ? " entry=\"title\"" : "") pause=\"inf\">\n"
            for button in buttons {
                xml += "        <button name=\"\(button.name)\"> \(command(for: button.action, page: index)) </button>\n"
            }
            xml += "        <vob file=\"\(escape(menuFiles[index]))\" pause=\"inf\" />\n      </pgc>\n"
        }
        xml += "    </menus>\n  </vmgm>\n  <titleset>\n"
        if !scenePages.isEmpty {
            xml += "    <menus>\n      <video format=\"\(standard.format)\" aspect=\"4:3\" />\n      <audio format=\"ac3\" lang=\"en\" />\n"
            for (index, buttons) in scenePages.enumerated() {
                xml += "      <pgc\(index == 0 ? " entry=\"ptt\"" : "") pause=\"inf\">\n"
                for button in buttons {
                    xml += "        <button name=\"\(button.name)\"> \(command(for: button.action, page: index)) </button>\n"
                }
                xml += "        <vob file=\"\(escape(sceneMenuFiles[index]))\" pause=\"inf\" />\n      </pgc>\n"
            }
            xml += "    </menus>\n"
        }
        xml += "    <titles>\n"
        xml += "      <video format=\"\(standard.format)\" aspect=\"\(widescreen ? "16:9" : "4:3")\"\(widescreen ? " widescreen=\"nopanscan\"" : "") />\n      <audio format=\"ac3\" lang=\"en\" />\n"
        for title in titles {
            let carryOn = title.number < titles.count ? "if (g1 eq 1) jump title \(title.number + 1); " : ""
            xml += "      <pgc>\n        <vob file=\"\(escape(title.file))\" chapters=\"\(chapterAttribute(seconds: title.seconds))\" />\n"
            // Started from a scene page: go back to the scenes. (Only the first scene page can be called, so that is where it lands.)
            let backToScenes = scenePages.isEmpty ? "" : "if (g2 eq 1) { g2 = 0; call menu entry ptt; } "
            xml += "        <post> \(carryOn)\(backToScenes)g1 = 0; call vmgm menu 1; </post>\n      </pgc>\n"
        }
        xml += "    </titles>\n  </titleset>\n</dvdauthor>\n"
        return xml
    }

    /// What spumux needs to put the buttons on one menu video. The three pictures are the blank base, the highlight, and the pressed look.
    public static func spumuxXML(standard: TVStandard, buttons: [DVDMenuButton], normal: String, highlight: String, select: String) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<subpictures format=\"\(standard.format)\">\n  <stream>\n"
        xml += "    <spu start=\"00:00:00.00\" image=\"\(escape(normal))\" highlight=\"\(escape(highlight))\" select=\"\(escape(select))\" force=\"yes\">\n"
        for b in buttons {
            xml += "      <button name=\"\(b.name)\" x0=\"\(b.x0)\" y0=\"\(b.y0)\" x1=\"\(b.x1)\" y1=\"\(b.y1)\" up=\"\(b.up)\" down=\"\(b.down)\" left=\"\(b.left)\" right=\"\(b.right)\" />\n"
        }
        xml += "    </spu>\n  </stream>\n</subpictures>\n"
        return xml
    }
}
