import Foundation
import XCTest
@testable import RippleKit

final class DVDMakerTests: XCTestCase {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(DVDBuildStage, Double)] = []
        func add(_ stage: DVDBuildStage, _ value: Double) { lock.withLock { items.append((stage, value)) } }
        var all: [(DVDBuildStage, Double)] { lock.withLock { items } }
    }

    func video(_ name: String, seconds: Double = 30) -> VideoFile {
        VideoFile(url: URL(fileURLWithPath: "/tmp/\(name).mp4"), title: name, bytes: 1, seconds: seconds, width: 1280, height: 720, framesPerSecond: 30, displayAspect: 16.0 / 9.0, hasAudio: true)
    }

    func project(_ names: [String]) -> DVDProject {
        DVDProject(files: names.map { video($0) }, discName: "Fixture", standard: .ntsc, widescreen: true)
    }

    func testTheFixtureReportsEveryStageInOrderAndEndsAtOne() async throws {
        let work = try DVDTestTools.tempFolder("ripple-fixture").appending(path: "work")
        let events = Events()
        let maker: any DVDMaker = FixtureDVDMaker(project: project(["A", "B"]), work: work)
        let result = try await maker.build { events.add($0, $1) }
        XCTAssertEqual(result.titles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.image.path))
        let stages = events.all.map(\.0)
        XCTAssertEqual(stages.first, .checking)
        XCTAssertEqual(stages.last, .done)
        let order = stages.map { stage -> Int in
            switch stage {
            case .checking: 0
            case .pictures: 1
            case .menus: 2
            case .converting: 3
            case .authoring: 4
            case .imaging: 5
            case .done: 6
            }
        }
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(stages.filter { if case .converting = $0 { true } else { false } }.count, 6)
        let values = events.all.map(\.1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(values.last, 1)
    }

    func testAFixtureFailureCleansUpLikeARealOne() async throws {
        let work = try DVDTestTools.tempFolder("ripple-fixture").appending(path: "work")
        let maker = FixtureDVDMaker(project: project(["A"]), work: work, failAt: .authoring)
        do {
            _ = try await maker.build { _, _ in }
            XCTFail("expected a failure")
        } catch let error as DVDBuildError {
            guard case .failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testTheFixtureRefusesTheSameProjectsTheRealBuilderRefuses() async throws {
        let work = try DVDTestTools.tempFolder("ripple-fixture").appending(path: "work")
        do {
            _ = try await FixtureDVDMaker(project: project([]), work: work).build { _, _ in }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DVDBuildError, .nothingToBuild)
        }
    }
}
