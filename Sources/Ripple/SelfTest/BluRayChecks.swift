import Foundation
import RippleKit

/// M8: the Blu-ray Disc type, on made-up videos and a made-up burner.
@MainActor
extension SelfTest {
    static func bluRayChecks(burn: BurnModel, dvd: DVDModel) async {
        let fm = FileManager.default
        burn.showSnapshot(.bluRayList)
        dvd.showSnapshot(.bluRayList)
        let state = burn.deviceState
        check("Blu-ray Disc is the fourth Disc Type", burn.type == .bluray && DiscType.allCases.last == .bluray)
        check("a blank BD-R is accepted for a Blu-ray Disc", burn.isReady && burn.deviceLine.contains("blank BD-R"), burn.deviceLine)
        check("a blank DVD-R is refused for a Blu-ray Disc", burn.imageProblem(bytes: 1_000_000, on: FixtureBurner.blankDVD())?.contains("blank BD-R or BD-RE") == true)
        check("a blank BD-R is refused for a Video DVD", { burn.type = .video; defer { burn.type = .bluray }; return !burn.isReady }())
        check("the screen follows the Disc Type", dvd.format == .bluray)

        let plan = dvd.plan(on: state)
        check("the plan uses the Blu-ray disc", plan.format == .bluray && plan.capacityBlocks == 12_219_392 && plan.fit == .fits)
        check("a Blu-ray is made in one HD shape from the first video", dvd.bluRayMode.title == "1080i29.97", dvd.bluRayMode.title)
        let project = dvd.project(on: state)
        check("the project carries the format and the disc's size", project.format == .bluray && project.capacityBlocks == 12_219_392)

        dvd.showSnapshot(.bluRayOver)
        check("far too many hours do not fit", !dvd.canBuild(on: state) && dvd.plan(on: state).fit != .fits)
        dvd.showSnapshot(.bluRayList)

        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work, stepDelay: .milliseconds(2)) }
        dvd.build(on: state)
        await wait(until: { if case .ready = dvd.phase { true } else { false } })
        guard case .ready(let result) = dvd.phase else { return check("the Blu-ray builds", false) }
        check("a finished Blu-ray holds the disc image", fm.fileExists(atPath: result.image.path))

        guard let burner = burn.burner as? FixtureBurner else { return }
        burner.stepDelay = .milliseconds(2)
        let before = burner.jobs.count
        burn.burnImage(result.image, volumeName: dvd.cleanDiscName)
        await wait(until: { burn.phase == .done })
        check("the image is burned as a Blu-ray job", burn.phase == .done && burner.jobs.count == before + 1
              && burner.jobs.last?.type == .bluray && burner.jobs.last?.files == [result.image])
        check("a burned disc no longer guards against quitting", !dvd.hasUnsavedDisc)

        burner.stepDelay = .milliseconds(5)
        dvd.startOver()
        dvd.makeMaker = { project, work in FixtureDVDMaker(project: project, work: work) }
        burn.showSnapshot(.empty)
        dvd.showSnapshot(.empty)
        dvd.format = .dvd
    }
}
