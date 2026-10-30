import AppKit

/// A long job that the quit prompt must ask about: ripping, burning.
@MainActor
protocol StoppableJob: AnyObject {
    var isBusy: Bool { get }
    /// The words for the quit prompt. `stop` is the button that ends the job; `keep` carries on.
    var stopPrompt: (title: String, detail: String, stop: String, keep: String) { get }
    /// Ends the job and waits for it to clean up.
    func stop() async
}

/// Every job that exists. The app delegate asks these before it quits.
@MainActor
enum Jobs {
    private static var registered: [() -> (any StoppableJob)?] = []

    static func register(_ job: some StoppableJob) {
        registered.append { [weak job] in job }
    }

    static var busy: [any StoppableJob] { registered.compactMap { $0() }.filter(\.isBusy) }
}
