import Foundation
import Observation
import RippleKit

/// Video DVD: the videos, the menu choices, and the build. The drive and the burn stay in `BurnModel`.
@Observable
final class DVDModel: StoppableJob {
    private(set) var videos: [VideoFile] = []

    init() { Jobs.register(self) }

    var isBusy: Bool { false }

    var stopPrompt: (title: String, detail: String, stop: String, keep: String) {
        ("Stop Making the Disc?", "The disc is not finished. If you quit now, the work so far is lost.", "Quit", "Keep Working")
    }

    func stop() async {}
}
