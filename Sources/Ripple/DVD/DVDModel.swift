import AppKit
import Foundation
import Observation
import RippleKit

/// One video in the list: being read, ready, or not usable.
struct DVDItem: Identifiable {
    enum State { case reading, ready(VideoFile), problem(VideoProblem) }

    var id: URL { url }
    var url: URL
    var state: State
    var picture: CGImage?
}

/// Video DVD: the videos, the menu choices, and the build. The drive and the burn stay in `BurnModel`.
@Observable
final class DVDModel: StoppableJob {
    private(set) var items: [DVDItem] = []
    /// Files left out of the list because they are not videos.
    private(set) var skipped = 0
    private(set) var isReading = false

    @ObservationIgnored private let source: any VideoSource

    init(source: any VideoSource = VideoSources.make()) {
        self.source = source
        Jobs.register(self)
    }

    /// The videos ffmpeg could read, in disc order.
    var videos: [VideoFile] {
        items.compactMap { if case .ready(let file) = $0.state { file } else { nil } }
    }

    var totalSeconds: Double { videos.reduce(0) { $0 + $1.seconds } }

    var tooMany: Bool { items.count > 99 }

    var isBusy: Bool { false }

    var stopPrompt: (title: String, detail: String, stop: String, keep: String) {
        ("Stop Making the Disc?", "The disc is not finished. If you quit now, the work so far is lost.", "Quit", "Keep Working")
    }

    func stop() async {}

    // MARK: Files

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose videos or folders of videos for the disc"
        panel.directoryURL = URL.moviesDirectory
        guard panel.runModal() == .OK else { return }
        Task { await add(panel.urls) }
    }

    /// Adds videos from dropped or chosen files and folders. Each shows "Reading…" until ffmpeg has looked at it.
    func add(_ urls: [URL]) async {
        let found = Self.videoFiles(in: urls)
        skipped += found.skipped
        let known = Set(items.map(\.id))
        let fresh = found.videos.filter { !known.contains($0) }
        items += fresh.map { DVDItem(url: $0, state: .reading) }
        isReading = true
        for url in fresh {
            let result = await source.read(url)
            guard let index = items.firstIndex(where: { $0.id == url }) else { continue }   // removed while reading
            switch result {
            case .success(let file):
                items[index].state = .ready(file)
                let picture = await source.picture(for: file)
                if let index = items.firstIndex(where: { $0.id == url }) { items[index].picture = picture }
            case .failure(let problem):
                items[index].state = .problem(problem)
            }
        }
        isReading = false
    }

    /// Video files in the dropped items (folders are searched), and how many other files were passed over.
    static func videoFiles(in urls: [URL]) -> (videos: [URL], skipped: Int) {
        var videos: [URL] = [], skipped = 0
        let fm = FileManager.default
        func visit(_ url: URL) {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
            if isFolder.boolValue {
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.forEach(visit)
            } else if VideoProbe.isVideoFile(url) {
                videos.append(url.standardizedFileURL)
            } else {
                skipped += 1
            }
        }
        urls.forEach(visit)
        return (videos, skipped)
    }

    // MARK: Snapshot

    /// A made-up list for the snapshot pages.
    func showSnapshot(_ page: BurnSnapshotPage) {
        skipped = 0
        items = []
        guard page == .videoList else { return }
        func video(_ name: String, _ seconds: Double) -> DVDItem {
            let url = URL(fileURLWithPath: "/Movies/\(name).mp4")
            let file = VideoFile(url: url, title: VideoProbe.defaultTitle(for: url), bytes: Int(seconds * 450_000), seconds: seconds,
                                 width: 1280, height: 720, framesPerSecond: 29.97, displayAspect: 16.0 / 9, hasAudio: true)
            return DVDItem(url: url, state: .ready(file), picture: FixtureVideoSource.gradient(seed: abs(name.hashValue)))
        }
        items = [video("Summer_Trip", 3_840), video("Birthday Party", 1_725), video("Beach Day", 905), video("First Steps", 142)]
        items.append(DVDItem(url: URL(fileURLWithPath: "/Movies/Rented Movie.m4v"), state: .problem(.copyProtected)))
        items.append(DVDItem(url: URL(fileURLWithPath: "/Movies/Old Tape.avi"), state: .reading))
        skipped = 2
    }
}
