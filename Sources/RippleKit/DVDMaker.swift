import Foundation

/// Anything that turns a `DVDProject` into a disc image. `DVDBuilder` is the real one;
/// `FixtureDVDMaker` is for tests, snapshots, and machines without ffmpeg and dvdauthor.
public protocol DVDMaker: Sendable {
    func build(progress: @escaping @Sendable (DVDBuildStage, Double) -> Void) async throws -> DVDBuildResult
}

extension DVDBuilder: DVDMaker {}

/// Reports every stage in order, writes a tiny stand-in image into `work`, and runs no program.
public struct FixtureDVDMaker: DVDMaker {
    public var project: DVDProject
    public var work: URL
    /// Fail when this stage is reached, with the same error and clean-up a real failure has.
    public var failAt: DVDBuildStage?
    /// How long each stage takes.
    public var stepDelay: Duration

    public init(project: DVDProject, work: URL, failAt: DVDBuildStage? = nil, stepDelay: Duration = .milliseconds(5)) {
        self.project = project; self.work = work; self.failAt = failAt; self.stepDelay = stepDelay
    }

    public func build(progress: @escaping @Sendable (DVDBuildStage, Double) -> Void) async throws -> DVDBuildResult {
        let fm = FileManager.default
        func report(_ stage: DVDBuildStage) async throws {
            try Task.checkCancellation()
            progress(stage, DVDBuilder.overall(stage, project: project))
            if let failAt, Self.sameStage(failAt, stage) { throw DVDBuildError.failed(step: "The fixture", detail: "Stopped at \(stage).") }
            try await Task.sleep(for: stepDelay)
        }
        do {
            try await report(.checking)
            guard !project.files.isEmpty else { throw DVDBuildError.nothingToBuild }
            guard project.files.count <= 99 else { throw DVDBuildError.tooManyTitles }
            guard project.plan.fit == .fits else { throw DVDBuildError.tooLong }
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await report(.pictures)
            try await report(.menus)
            let count = project.files.count
            for (index, file) in project.files.enumerated() {
                for fraction in [0.0, 0.5, 1.0] {
                    try await report(.converting(title: index + 1, of: count, name: file.title, fraction: fraction))
                }
            }
            try await report(.authoring)
            try await report(.imaging)
            let image = work.appending(path: "disc.iso")
            try Data("fixture".utf8).write(to: image)
            try await report(.done)
            return DVDBuildResult(image: image, work: work, titles: count)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Same kind of stage; the numbers inside `.converting` do not matter.
    static func sameStage(_ a: DVDBuildStage, _ b: DVDBuildStage) -> Bool {
        switch (a, b) {
        case (.converting, .converting): true
        default: a == b
        }
    }
}
