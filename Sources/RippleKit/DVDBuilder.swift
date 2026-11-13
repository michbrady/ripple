import CoreGraphics
import Foundation
import ImageIO

/// The programs the DVD feature runs. Each is a separate program inside the app.
public struct DVDTools: Sendable {
    public var ffmpeg: URL
    public var dvdauthor: URL
    public var spumux: URL
    public var hdiutil: URL
    public init(ffmpeg: URL, dvdauthor: URL, spumux: URL, hdiutil: URL = URL(fileURLWithPath: "/usr/bin/hdiutil")) {
        self.ffmpeg = ffmpeg; self.dvdauthor = dvdauthor; self.spumux = spumux; self.hdiutil = hdiutil
    }
}

/// Everything the user decided.
public struct DVDProject: Sendable {
    public var files: [VideoFile]
    public var discName: String
    public var standard: TVStandard
    public var widescreen: Bool
    public var look: MenuLook
    /// A picture for the menu background, and a sound file to play under the menu.
    public var background: URL?
    public var music: URL?
    public var capacityBlocks: Int
    public var format: VideoDiscFormat

    public init(files: [VideoFile], discName: String, standard: TVStandard, widescreen: Bool, look: MenuLook = .classic,
                background: URL? = nil, music: URL? = nil, capacityBlocks: Int? = nil, format: VideoDiscFormat = .dvd) {
        self.files = files; self.discName = discName; self.standard = standard; self.widescreen = widescreen
        self.look = look; self.background = background; self.music = music; self.format = format
        self.capacityBlocks = capacityBlocks ?? format.singleLayerBlocks
    }

    public var plan: DVDPlan { DVDPlan(files: files, standard: standard, capacityBlocks: capacityBlocks, format: format) }
}

public enum DVDBuildStage: Equatable, Sendable {
    case checking
    case pictures
    /// Title `title` of `of` (both from 1), `fraction` of that title done.
    case converting(title: Int, of: Int, name: String, fraction: Double)
    case menus
    case authoring
    case imaging
    case done
}

public enum DVDBuildError: Error, Equatable, LocalizedError, Sendable {
    case nothingToBuild
    case tooLong
    case tooManyTitles
    case toolMissing(String)
    case notEnoughSpace(needed: Int, free: Int)   // in megabytes
    case failed(step: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .nothingToBuild: "There are no videos to put on the disc."
        case .tooLong: "The videos are too long for one disc. Remove some and try again."
        case .tooManyTitles: "A DVD holds 99 videos at most."
        case .toolMissing(let name): "\(name) is missing from Ripple, so it cannot make a Video DVD."
        case .notEnoughSpace(let needed, let free): "Ripple needs about \(needed) MB of free space on this Mac to make the disc, and \(free) MB is free."
        case .failed(let step, let detail): "\(step) did not work. \(detail)"
        }
    }
}

public struct DVDBuildResult: Equatable, Sendable {
    /// The disc image, ready to burn or save. It lives in `work`.
    public var image: URL
    /// Every file the build made. Delete it when the image is burned or copied away.
    public var work: URL
    public var titles: Int

    public init(image: URL, work: URL, titles: Int) { self.image = image; self.work = work; self.titles = titles }
}

/// Turns a `DVDProject` into a disc image: pictures, menus, converted videos, the disc's files, and the image.
public struct DVDBuilder: Sendable {
    public var tools: DVDTools
    public var project: DVDProject
    public var work: URL

    public init(tools: DVDTools, project: DVDProject, work: URL) {
        self.tools = tools; self.project = project; self.work = work
    }

    /// Overall progress, 0 to 1, for each stage's share of the time.
    static func overall(_ stage: DVDBuildStage, project: DVDProject) -> Double {
        let total = max(1, project.files.reduce(0) { $0 + $1.seconds })
        switch stage {
        case .checking: return 0
        case .pictures: return 0.01
        case .menus: return 0.03
        case .converting(let title, _, _, let fraction):
            let before = project.files.prefix(title - 1).reduce(0) { $0 + $1.seconds }
            return 0.05 + 0.85 * (before + project.files[title - 1].seconds * fraction) / total
        case .authoring: return 0.92
        case .imaging: return 0.96
        case .done: return 1
        }
    }

    public func build(progress: @escaping @Sendable (DVDBuildStage, Double) -> Void) async throws -> DVDBuildResult {
        let fm = FileManager.default
        func report(_ stage: DVDBuildStage) { progress(stage, Self.overall(stage, project: project)) }
        do {
            report(.checking)
            try check()
            for folder in ["titles", "menu", "thumbs", "disc"] { try fm.createDirectory(at: work.appending(path: folder), withIntermediateDirectories: true) }

            // 1. A picture from each video for its button.
            report(.pictures)
            var thumbs: [CGImage?] = []
            for (index, file) in project.files.enumerated() {
                let out = work.appending(path: "thumbs/\(index + 1).png")
                let at = min(10, max(0, file.seconds * 0.1))
                let r = try await ProcessRunner.run(tools.ffmpeg, DVDAuthoring.thumbnailArguments(input: file.url, output: out, at: at))
                thumbs.append(r.status == 0 ? Self.load(out) : nil)   // a missing picture leaves a black button, not a failed disc
            }
            // A picture for each chapter of a title that has chapters, for the scene pages.
            var chapterPictures: [[CGImage?]] = []
            for (index, file) in project.files.enumerated() {
                var pictures: [CGImage?] = []
                let starts = DVDAuthoring.chapterStarts(seconds: file.seconds)
                if starts.count > 1 {
                    for (chapter, start) in starts.enumerated() {
                        let out = work.appending(path: "thumbs/\(index + 1)-\(chapter + 1).png")
                        let at = min(start + 5, max(0, file.seconds - 1))
                        let r = try await ProcessRunner.run(tools.ffmpeg, DVDAuthoring.thumbnailArguments(input: file.url, output: out, at: at))
                        pictures.append(r.status == 0 ? Self.load(out) : nil)
                    }
                }
                chapterPictures.append(pictures)
            }

            // 2. The menu pages, and the buttons laid over them.
            report(.menus)
            let titles = project.files.enumerated().map { DVDMenuTitle(name: $0.element.title, thumbnail: thumbs[$0.offset], seconds: $0.element.seconds, chapterPictures: chapterPictures[$0.offset]) }
            let background = project.background.flatMap { Self.load($0) }
            let pages = DVDMenuRenderer.render(discName: project.discName, titles: titles, standard: project.standard, look: project.look, background: background)
            var menuFiles: [String] = [], sceneMenuFiles: [String] = []
            // The menu video lasts as long as the music (5 to 90 seconds), or 5 seconds in silence.
            var menuSeconds = 5
            if let music = project.music {
                let report = try await ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-i", music.path])
                if let length = VideoProbe.seconds(in: report.error + report.output) { menuSeconds = min(90, max(5, Int(length.rounded()))) }
            }
            for (index, page) in pages.enumerated() {
                let n = index + 1, menu = work.appending(path: "menu")
                try page.picture.write(to: menu.appending(path: "page\(n).png"))
                try page.highlight.write(to: menu.appending(path: "highlight\(n).png"))
                try page.select.write(to: menu.appending(path: "select\(n).png"))
                try DVDMenuRenderer.blank(standard: project.standard).write(to: menu.appending(path: "normal.png"))
                let plain = menu.appending(path: "plain\(n).mpg"), final = menu.appending(path: "menu\(n).mpg")
                                let made = try await ProcessRunner.run(tools.ffmpeg, DVDAuthoring.menuVideoArguments(picture: menu.appending(path: "page\(n).png"), music: project.music, seconds: menuSeconds, standard: project.standard, output: plain))
                guard made.status == 0 else { throw DVDBuildError.failed(step: "Making the menu", detail: Self.tail(made.error)) }
                let xml = DVDAuthoring.spumuxXML(standard: project.standard, buttons: page.buttons, normal: "normal.png", highlight: "highlight\(n).png", select: "select\(n).png")
                try xml.write(to: menu.appending(path: "buttons\(n).xml"), atomically: true, encoding: .utf8)
                let buttons = try await ProcessRunner.run(tools.spumux, ["buttons\(n).xml"], input: plain, outputFile: final,
                                                          environment: ["VIDEO_FORMAT": project.standard.format.uppercased()], directory: menu)
                guard buttons.status == 0, (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
                    throw DVDBuildError.failed(step: "Adding the menu buttons", detail: Self.tail(buttons.error))
                }
                try? fm.removeItem(at: plain)
                if page.kind == .main { menuFiles.append("menu/menu\(n).mpg") } else { sceneMenuFiles.append("menu/menu\(n).mpg") }
            }

            // 3. Convert every video. This is the slow part.
            let plan = project.plan
            var specs: [DVDTitleSpec] = []
            for (index, file) in project.files.enumerated() {
                let number = index + 1
                let out = work.appending(path: "titles/title\(number).mpg")
                let geometry = DVDGeometry.fit(displayAspect: file.displayAspect, widescreen: project.widescreen, standard: project.standard)
                report(.converting(title: number, of: project.files.count, name: file.title, fraction: 0))
                let seconds = file.seconds
                let r = try await ProcessRunner.run(tools.ffmpeg, DVDAuthoring.convertArguments(input: file.url, output: out, geometry: geometry, standard: project.standard,
                                                                                               videoKbps: plan.videoKbps, hasAudio: file.hasAudio)) { line in
                    if let fraction = DVDAuthoring.progress(line: line, total: seconds) {
                        progress(.converting(title: number, of: project.files.count, name: file.title, fraction: fraction),
                                 Self.overall(.converting(title: number, of: project.files.count, name: file.title, fraction: fraction), project: project))
                    }
                }
                guard r.status == 0 else { throw DVDBuildError.failed(step: "Converting \u{201C}\(file.title)\u{201D}", detail: Self.tail(r.error)) }
                specs.append(DVDTitleSpec(number: number, name: file.title, file: "titles/title\(number).mpg", seconds: file.seconds))
            }

            // 4. The disc's own files.
            report(.authoring)
            let xml = DVDAuthoring.authorXML(standard: project.standard, widescreen: project.widescreen, titles: specs, pages: pages.filter { $0.kind == .main }.map(\.buttons), menuFiles: menuFiles,
                                            scenePages: pages.filter { $0.kind == .scenes }.map(\.buttons), sceneMenuFiles: sceneMenuFiles)
            try xml.write(to: work.appending(path: "dvd.xml"), atomically: true, encoding: .utf8)
            let disc = work.appending(path: "disc")
            let authored = try await ProcessRunner.run(tools.dvdauthor, ["-o", disc.path, "-x", work.appending(path: "dvd.xml").path],
                                                       environment: ["VIDEO_FORMAT": project.standard.format.uppercased()], directory: work)
            guard authored.status == 0, fm.fileExists(atPath: disc.appending(path: "VIDEO_TS/VIDEO_TS.IFO").path) else {
                throw DVDBuildError.failed(step: "Writing the disc files", detail: Self.tail(authored.error))
            }
            try? fm.createDirectory(at: disc.appending(path: "AUDIO_TS"), withIntermediateDirectories: true)
            // The converted videos are inside the disc's files now; free their space before the image is made.
            try? fm.removeItem(at: work.appending(path: "titles"))

            // 5. The disc image.
            report(.imaging)
            let label = DVDName.volumeLabel(project.discName)
            let image = work.appending(path: "disc.iso")
            let made = try await ProcessRunner.run(tools.hdiutil, ["makehybrid", "-udf", "-udf-version", "1.02", "-iso", "-iso-volume-name", label,
                                                                   "-udf-volume-name", label, "-default-volume-name", label, "-o", image.path, disc.path])
            guard made.status == 0, fm.fileExists(atPath: image.path) else { throw DVDBuildError.failed(step: "Making the disc image", detail: Self.tail(made.error + made.output)) }
            try? fm.removeItem(at: disc)
            // hdiutil scatters the disc's files in an order of its own. A DVD player finds the video by counting sectors from each
            // .IFO file, so the files must sit in DVD order. If the image is not what this expects it is kept as it is.
            try? DVDImageOrder.reorder(image: image)
            report(.done)
            return DVDBuildResult(image: image, work: work, titles: specs.count)
        } catch {
            // Nothing half-made is left behind, whether it failed or was cancelled.
            try? fm.removeItem(at: work)
            throw error
        }
    }

    func check() throws {
        guard !project.files.isEmpty else { throw DVDBuildError.nothingToBuild }
        guard project.files.count <= 99 else { throw DVDBuildError.tooManyTitles }
        guard project.plan.fit == .fits else { throw DVDBuildError.tooLong }
        for (name, url) in [("ffmpeg", tools.ffmpeg), ("dvdauthor", tools.dvdauthor), ("spumux", tools.spumux)] where !FileManager.default.isExecutableFile(atPath: url.path) {
            throw DVDBuildError.toolMissing(name)
        }
        // The converted videos and the disc's files exist side by side for a while: about twice the disc, plus a margin.
        let needed = project.plan.convertedBytes * 2 + 500_000_000
        let folder = work.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, Int(free) < needed {
            throw DVDBuildError.notEnoughSpace(needed: needed / 1_000_000, free: Int(free) / 1_000_000)
        }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The last few lines of a program's error text, for a message a person can read.
    static func tail(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(3).joined(separator: " ")
    }
}

extension DVDMenuRenderer {
    /// A fully transparent picture, the base the button overlays sit on.
    public static func blank(standard: TVStandard) -> Data { png(context(standard).makeImage()!) }
}
