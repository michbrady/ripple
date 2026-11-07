import Foundation

/// The programs the Blu-ray feature runs. Each is a separate program inside the app.
public struct BluRayTools: Sendable {
    public var ffmpeg: URL
    public var tsmuxer: URL
    public init(ffmpeg: URL, tsmuxer: URL) { self.ffmpeg = ffmpeg; self.tsmuxer = tsmuxer }
}

/// Makes a Blu-ray disc image: ffmpeg converts every video to HD picture and AC-3 sound, and tsMuxeR joins them into one program
/// with a chapter for each video and writes the disc (`BDMV` folder, UDF 2.5) as an image. There is no menu; the disc plays at once.
public struct BluRayBuilder: DVDMaker {
    public var tools: BluRayTools
    public var project: DVDProject
    public var work: URL

    public init(tools: BluRayTools, project: DVDProject, work: URL) {
        self.tools = tools; self.project = project; self.work = work
    }

    public func build(progress: @escaping @Sendable (DVDBuildStage, Double) -> Void) async throws -> DVDBuildResult {
        let fm = FileManager.default
        func report(_ stage: DVDBuildStage) { progress(stage, DVDBuilder.overall(stage, project: project)) }
        do {
            report(.checking)
            try check()
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let mode = BluRayMode.suggest(for: project.files)
            let plan = project.plan

            // 1. Convert every video. This is the slow part.
            var converted: [String] = []
            for (index, file) in project.files.enumerated() {
                let number = index + 1
                let name = "title\(number).mkv"
                report(.converting(title: number, of: project.files.count, name: file.title, fraction: 0))
                let seconds = file.seconds
                let r = try await ProcessRunner.run(tools.ffmpeg, BluRayAuthoring.convertArguments(
                    input: file.url, output: work.appending(path: name), mode: mode,
                    videoKbps: plan.videoKbps, hasAudio: file.hasAudio, seconds: seconds)) { line in
                    if let fraction = DVDAuthoring.progress(line: line, total: seconds) {
                        let stage = DVDBuildStage.converting(title: number, of: project.files.count, name: file.title, fraction: fraction)
                        progress(stage, DVDBuilder.overall(stage, project: project))
                    }
                }
                guard r.status == 0 else { throw DVDBuildError.failed(step: "Converting \u{201C}\(file.title)\u{201D}", detail: DVDBuilder.tail(r.error)) }
                converted.append(name)
            }

            // 2. Join them into one program and write the disc image.
            report(.authoring)
            let label = DVDName.volumeLabel(project.discName)
            let meta = BluRayAuthoring.metaFile(files: converted, seconds: project.files.map(\.seconds), mode: mode, label: label)
            try meta.write(to: work.appending(path: "disc.meta"), atomically: true, encoding: .utf8)
            report(.imaging)
            let image = work.appending(path: "disc.iso")
            let made = try await ProcessRunner.run(tools.tsmuxer, ["disc.meta", "disc.iso"], directory: work)
            guard made.status == 0, fm.fileExists(atPath: image.path) else {
                throw DVDBuildError.failed(step: "Making the disc image", detail: DVDBuilder.tail(made.error + made.output))
            }
            for name in converted + ["disc.meta"] { try? fm.removeItem(at: work.appending(path: name)) }
            report(.done)
            return DVDBuildResult(image: image, work: work, titles: project.files.count)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    func check() throws {
        guard !project.files.isEmpty else { throw DVDBuildError.nothingToBuild }
        guard project.plan.fit == .fits else { throw DVDBuildError.tooLong }
        for (name, url) in [("ffmpeg", tools.ffmpeg), ("tsMuxeR", tools.tsmuxer)] where !FileManager.default.isExecutableFile(atPath: url.path) {
            throw DVDBuildError.toolMissing(name)
        }
        // The converted files and the image exist side by side for a while.
        let needed = project.plan.convertedBytes * 2 + 500_000_000
        let folder = work.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, Int(free) < needed {
            throw DVDBuildError.notEnoughSpace(needed: needed / 1_000_000, free: Int(free) / 1_000_000)
        }
    }
}
