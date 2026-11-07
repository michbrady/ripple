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

    /// The rows selected in the list. Move Up, Move Down, and Remove act on these.
    var selection = Set<URL>()
    /// Edit > Undo for removing, moving, and renaming.
    var undoManager: UndoManager?

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

    /// The name at the top of the menu and on the disc.
    var discName = "My Videos"
    /// The menu's look.
    var look: MenuLook = .classic
    /// Whether the Menu inspector is open.
    var showsMenu = false

    /// `discName` cleaned the way the menu shows it.
    var cleanDiscName: String { DVDName.cleaned(discName, fallback: "Video DVD", limit: DVDName.maxDisc) }

    /// What the user chose in the bar. `nil` follows the videos.
    var standardChoice: TVStandard?
    var widescreenChoice: Bool?

    /// NTSC or PAL: the user's choice, or what the first video suggests.
    var standard: TVStandard { standardChoice ?? TVStandard.suggest(for: videos) }

    /// One frame shape for the whole disc: the user's choice, or widescreen when at least half the videos are.
    var widescreen: Bool {
        if let widescreenChoice { return widescreenChoice }
        let wide = videos.filter(\.isWidescreen).count
        return videos.isEmpty || wide * 2 >= videos.count
    }

    /// Said under the bar when the videos disagree and the user has not chosen.
    var mixedNote: String? {
        guard standardChoice == nil, TVStandard.mixed(videos) else { return nil }
        return "Videos use different standards. Ripple used \(standard.title), from the first one."
    }

    /// The plan on the disc in the drive, or on a single-layer DVD when there is none.
    func plan(on state: BurnDeviceState) -> DVDPlan {
        DVDPlan(files: videos, standard: standard, capacityBlocks: DVDPlan.capacity(for: state))
    }

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

    // MARK: Order, names, and removing

    func title(of id: URL) -> String? {
        guard let item = items.first(where: { $0.id == id }), case .ready(let file) = item.state else { return nil }
        return file.title
    }

    /// Renames a title, cut and cleaned for the menu. An empty name goes back to the file's own.
    func rename(_ id: URL, to text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .ready(var file) = items[index].state else { return }
        let title = DVDName.cleaned(text, fallback: VideoProbe.defaultTitle(for: id))
        guard title != file.title else { return }
        let before = items
        file.title = title
        items[index].state = .ready(file)
        registerUndo("Rename Video", from: before)
    }

    func remove(ids: Set<URL>) {
        guard !ids.isEmpty else { return }
        let before = items
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        registerUndo(ids.count == 1 ? "Remove Video" : "Remove \(ids.count) Videos", from: before)
    }

    func move(from source: IndexSet, to destination: Int) {
        let before = items
        items.move(fromOffsets: source, toOffset: destination)
        registerUndo("Reorder Videos", from: before)
    }

    var canMoveUp: Bool { selectedIndexes.first.map { $0 > 0 } ?? false }
    var canMoveDown: Bool { selectedIndexes.last.map { $0 < items.count - 1 } ?? false }

    func moveSelectionUp() {
        guard canMoveUp else { return }
        move(from: IndexSet(selectedIndexes), to: selectedIndexes[0] - 1)
    }

    func moveSelectionDown() {
        guard canMoveDown else { return }
        move(from: IndexSet(selectedIndexes), to: selectedIndexes[selectedIndexes.count - 1] + 2)
    }

    private var selectedIndexes: [Int] { items.indices.filter { selection.contains(items[$0].id) } }

    private func registerUndo(_ name: String, from before: [DVDItem]) {
        undoManager?.registerUndo(withTarget: self) { model in model.restore(before) }
        undoManager?.setActionName(name)
    }

    private func restore(_ state: [DVDItem]) {
        let current = items
        items = state
        undoManager?.registerUndo(withTarget: self) { model in model.restore(current) }
    }

    // MARK: Snapshot

    /// A made-up list for the snapshot pages.
    func showSnapshot(_ page: BurnSnapshotPage) {
        skipped = 0
        items = []
        showsMenu = page == .videoMenu || page == .videoMenuDaylight
        look = page == .videoMenuDaylight ? .daylight : .classic
        guard page == .videoList || page == .videoOver || page == .videoMenu || page == .videoMenuDaylight else { return }
        func video(_ name: String, _ seconds: Double) -> DVDItem {
            let url = URL(fileURLWithPath: "/Movies/\(name).mp4")
            let file = VideoFile(url: url, title: VideoProbe.defaultTitle(for: url), bytes: Int(seconds * 450_000), seconds: seconds,
                                 width: 1280, height: 720, framesPerSecond: 29.97, displayAspect: 16.0 / 9, hasAudio: true)
            return DVDItem(url: url, state: .ready(file), picture: FixtureVideoSource.gradient(seed: abs(name.hashValue)))
        }
        items = [video("Summer_Trip", 3_840), video("Birthday Party", 1_725), video("Beach Day", 905), video("First Steps", 142)]
        if page == .videoMenu || page == .videoMenuDaylight {
            items = [video("Summer_Trip", 3_840), video("Birthday Party", 1_725), video("Beach Day", 905), video("First Steps", 142),
                     video("Wedding", 1_800), video("Honeymoon", 1_200), video("Graduation", 900)]
            discName = "Summer Trip"
            return
        }
        if page == .videoOver {
            items += [video("Wedding", 5_400), video("Honeymoon", 4_800), video("Graduation", 3_900)]
            skipped = 0
            return
        }
        items.append(DVDItem(url: URL(fileURLWithPath: "/Movies/Rented Movie.m4v"), state: .problem(.copyProtected)))
        items.append(DVDItem(url: URL(fileURLWithPath: "/Movies/Old Tape.avi"), state: .reading))
        skipped = 2
    }
}
