import AppKit
import Foundation
import Observation
import RippleKit

enum AppMode: String, CaseIterable, Identifiable {
    case rip, burn

    var id: String { rawValue }
    var title: String { self == .rip ? "Rip" : "Burn" }
}

/// Burn mode: MP3 and M4A files (in folders, for an MP3 Disc), the disc type, the blank disc, and the burn itself.
@Observable
final class BurnModel: StoppableJob {
    enum Phase: Equatable {
        case editing
        case burning(BurnStage)
        case done
        case failed(String)
    }

    static weak var current: BurnModel?

    var items: [BurnItem] = []
    /// Folders made by hand for an MP3 Disc, empty ones included. Folders that hold files exist without being listed here.
    private(set) var madeFolders: [String] = []
    private(set) var sourceFolder: URL?
    /// Files left out of the list: not MP3 or M4A, or not readable as audio.
    private(set) var skipped = 0
    private(set) var isScanning = false
    var phase: Phase = .editing
    private(set) var deviceState: BurnDeviceState
    var isCancelling = false
    /// Edit > Undo for removing files.
    var undoManager: UndoManager?

    var type: DiscType = .audio {
        didSet { defaults.set(type.rawValue, forKey: "burn.type") }
    }

    private let defaults: UserDefaults
    let burner: any DiscBurner
    private var burnTask: Task<Void, Never>?
    private var watcher: Task<Void, Never>?

    init(burner: any DiscBurner, defaults: UserDefaults = Store.defaults) {
        self.burner = burner
        self.defaults = defaults
        self.deviceState = burner.state()
        Self.current = self
        type = DiscType(rawValue: defaults.string(forKey: "burn.type") ?? "") ?? .audio
        Jobs.register(self)
    }

    /// Starts watching the drive.
    func start() {
        guard watcher == nil else { return }
        let changes = burner.stateChanges()
        deviceState = burner.state()
        watcher = Task { [weak self] in
            for await state in changes { self?.deviceState = state }
        }
    }

    // MARK: Plan

    var plan: BurnPlan { BurnPlan(items: items, type: type) }
    var fit: BurnPlan.Fit { plan.fit(on: deviceState) }
    var deviceName: String { burner.deviceName ?? "Burner" }

    var isReady: Bool {
        guard case .ready(let media) = deviceState else { return false }
        return type != .video || media.kind == .dvd
    }

    var canBurn: Bool { phase == .editing && isReady && fit == .fits }

    /// One line about the drive and the disc in it.
    var deviceLine: String {
        switch deviceState {
        case .noDrive: "Connect a USB burner to burn a disc."
        case .noDisc:
            switch type {
            case .audio: "Insert a blank CD-R."
            case .data: "Insert a blank CD-R or DVD-R."
            case .video: "Insert a blank DVD-R or DVD-RW."
            }
        case .notBlank(let label, let rewritable):
            rewritable ? "This \(label) is not blank. Erase it in Disk Utility, then insert it again."
                       : "This \(label) is not blank. Insert a blank disc."
        case .ready(let media):
            isReady ? "\(deviceName) · blank \(media.label)" : "Insert a blank DVD-R or DVD-RW. This disc is a \(media.label)."
        }
    }

    /// The warning under the capacity bar, when there is one.
    var fitMessage: String? {
        switch fit {
        case .wrongMedia(let text): text
        case .over(let blocks): "Remove \(plan.overText(blocks: blocks).replacingOccurrences(of: " over", with: "")) to fit on the disc."
        case .fits, .nothingToBurn: nil
        }
    }

    /// A heads-up that does not stop the burn: a CD-RW will not play in many older players.
    var compatibilityNote: String? {
        guard type == .audio, case .ready(let media) = deviceState, media.label == "CD-RW" else { return nil }
        return "Many older CD players cannot read CD-RW discs. A blank CD-R plays in more players."
    }

    /// An MP3 Disc holds MP3 files, so M4A files on it are converted. Said before the burn, not after.
    var conversionNote: String? {
        guard type == .data else { return nil }
        let count = items.filter { !$0.isMP3 }.count
        guard count > 0 else { return nil }
        return "\(count) M4A \(count == 1 ? "file is" : "files are") converted to MP3 when the disc is burned."
    }

    /// Every folder on the disc, in name order.
    var folderPaths: [String] { DiscLayout.allFolders(items: items, made: madeFolders) }

    /// The list shows folders on an MP3 Disc once there is one.
    var showsFolders: Bool { type == .data && !folderPaths.isEmpty }

    var volumeName: String {
        let name = sourceFolder?.lastPathComponent ?? ""
        return name.isEmpty ? "MP3 Disc" : name
    }

    var windowTitle: String { "Ripple" }

    // MARK: Files

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of MP3 or M4A files to burn"
        if let sourceFolder { panel.directoryURL = sourceFolder } else { panel.directoryURL = URL.musicDirectory }
        if panel.runModal() == .OK, let url = panel.url { load(folder: url) }
    }

    func load(folder: URL) {
        isScanning = true
        sourceFolder = folder
        madeFolders = []
        Task {
            let scan = await BurnScanner.scan(folder)
            items = scan.items
            skipped = scan.skipped
            isScanning = false
            phase = .editing
        }
    }

    /// Adds dropped files and folders to the list. Files already listed are not added twice. On an MP3 Disc,
    /// `folder` is where they land; a dropped folder keeps its own name inside it.
    func add(dropped urls: [URL], into folder: String = "") async {
        isScanning = true
        let scan = await BurnScanner.scan(dropped: urls)
        let known = Set(items.map(\.id))
        items += scan.items.filter { !known.contains($0.id) }.map { item in
            var placed = item
            placed.folder = DiscLayout.join(folder, item.folder)
            return placed
        }
        skipped += scan.skipped
        if sourceFolder == nil, urls.count == 1 { sourceFolder = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent() }
        isScanning = false
        phase = .editing
    }

    /// What Undo brings back: the list and its folders.
    private struct Snapshot { var items: [BurnItem]; var folders: [String] }

    private func registerUndo(_ name: String, from before: Snapshot) {
        undoManager?.registerUndo(withTarget: self) { model in model.restore(before) }
        undoManager?.setActionName(name)
    }

    private var snapshot: Snapshot { Snapshot(items: items, folders: madeFolders) }

    /// Files dropped on a folder: ones already in the list move there, new ones are added there.
    func drop(_ urls: [URL], into folder: String) async {
        let known = Dictionary(items.map { ($0.id, $0.id) }, uniquingKeysWith: { first, _ in first })
        let ids = urls.compactMap { known[$0.resolvingSymlinksInPath().standardizedFileURL.path] }
        if !ids.isEmpty, type == .data { move(ids: Set(ids), toFolder: folder) }
        let fresh = urls.filter { known[$0.resolvingSymlinksInPath().standardizedFileURL.path] == nil }
        if !fresh.isEmpty { await add(dropped: fresh, into: type == .data ? folder : "") }
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = snapshot
        items.removeAll { ids.contains($0.id) }
        registerUndo(ids.count == 1 ? "Remove File" : "Remove \(ids.count) Files", from: before)
    }

    func move(from source: IndexSet, to destination: Int) {
        let before = snapshot
        items.move(fromOffsets: source, toOffset: destination)
        registerUndo("Reorder Files", from: before)
    }

    private func restore(_ state: Snapshot) {
        let current = snapshot
        items = state.items
        madeFolders = state.folders
        undoManager?.registerUndo(withTarget: self) { model in model.restore(current) }
    }

    // MARK: Folders (MP3 Disc)

    /// The files in one folder, in disc order.
    func items(in folder: String) -> [BurnItem] { items.filter { $0.folder == folder } }

    /// Makes a folder inside `parent` and returns its path. Names are cleaned and kept unique.
    @discardableResult
    func makeFolder(named name: String, in parent: String = "") -> String {
        let before = snapshot
        let path = DiscLayout.join(parent, DiscLayout.newFolderName(name, in: parent, existing: folderPaths))
        madeFolders.append(path)
        registerUndo("New Folder", from: before)
        return path
    }

    func renameFolder(_ path: String, to name: String) {
        let parent = DiscLayout.parent(of: path)
        let others = folderPaths.filter { $0 != path }
        let new = DiscLayout.join(parent, DiscLayout.newFolderName(name, in: parent, existing: others))
        guard new != path else { return }
        let before = snapshot
        func renamed(_ value: String) -> String {
            if value == path { return new }
            return value.hasPrefix(path + "/") ? new + value.dropFirst(path.count) : value
        }
        madeFolders = madeFolders.map(renamed)
        for index in items.indices { items[index].folder = renamed(items[index].folder) }
        registerUndo("Rename Folder", from: before)
    }

    /// Removes a folder from the disc. Its files and folders move up one level; no file is left out.
    func removeFolder(_ path: String) {
        let parent = DiscLayout.parent(of: path)
        let before = snapshot
        func lifted(_ value: String) -> String {
            if value == path { return parent }
            return value.hasPrefix(path + "/") ? DiscLayout.join(parent, String(value.dropFirst(path.count + 1))) : value
        }
        madeFolders = madeFolders.filter { $0 != path }.map(lifted)
        for index in items.indices { items[index].folder = lifted(items[index].folder) }
        registerUndo("Remove Folder", from: before)
    }

    /// Puts files in a folder ("" is the top of the disc).
    func move(ids: Set<String>, toFolder folder: String) {
        guard items.contains(where: { ids.contains($0.id) && $0.folder != folder }) else { return }
        let before = snapshot
        for index in items.indices where ids.contains(items[index].id) { items[index].folder = folder }
        registerUndo(ids.count == 1 ? "Move File" : "Move \(ids.count) Files", from: before)
    }

    /// Moves a file up or down among the files of its folder.
    func nudge(id: String, by offset: Int) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let siblings = items.indices.filter { items[$0].folder == item.folder }
        guard let position = siblings.firstIndex(where: { items[$0].id == id }) else { return }
        let target = position + offset
        guard siblings.indices.contains(target) else { return }
        let before = snapshot
        items.swapAt(siblings[position], siblings[target])
        registerUndo("Reorder Files", from: before)
    }

    func clear() {
        items = []
        madeFolders = []
        sourceFolder = nil
        skipped = 0
        phase = .editing
    }

    // MARK: Burn

    var isBurning: Bool { if case .burning = phase { true } else { false } }

    /// Cancel works until writing starts.
    var canCancel: Bool { phase == .burning(.preparing) && !isCancelling }

    func burn() {
        guard canBurn else { return }
        let job = BurnJob(type: type, files: items.map(\.url), volumeName: volumeName,
                          placements: type == .data ? items.map(\.folder) : [], folders: type == .data ? folderPaths : [])
        isCancelling = false
        phase = .burning(.preparing)
        let burner = burner
        burnTask = Task { [weak self] in
            do {
                try await burner.burn(job) { stage in
                    Task { @MainActor in self?.stage(stage) }
                }
                self?.phase = .done
            } catch is CancellationError {
                self?.phase = .editing
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.isCancelling = false
            self?.burnTask = nil
        }
    }

    private func stage(_ stage: BurnStage) {
        guard isBurning else { return }
        phase = .burning(stage)
    }

    func cancel() {
        guard canCancel else { return }
        isCancelling = true
        burnTask?.cancel()
    }

    func tryAgain() { phase = .editing }

    func eject() { burner.eject() }

    // MARK: StoppableJob

    var isBusy: Bool { isBurning }

    var stopPrompt: (title: String, detail: String, stop: String, keep: String) {
        phase == .burning(.preparing)
            ? ("Stop Burning?", "Nothing has been written yet. The disc stays as it is.", "Stop", "Keep Burning")
            : ("Quit While Burning?", "Stopping now ruins the disc.", "Quit Anyway", "Keep Burning")
    }

    func stop() async {
        burnTask?.cancel()
        await burnTask?.value
    }

    // MARK: Snapshot pages

    /// Puts the window in the state a snapshot shows, on made-up files and a made-up burner.
    func showSnapshot(_ page: BurnSnapshotPage) {
        watcher?.cancel()
        watcher = nil
        func file(_ n: Int, _ title: String, _ artist: String, _ seconds: Double) -> BurnItem {
            BurnItem(url: URL(fileURLWithPath: "/Music/Mix/\(String(format: "%02d", n)) \(title).mp3"), title: title,
                     artist: artist, seconds: seconds, bytes: Int(seconds * 24_000), trackNumber: n)
        }
        let list = [file(1, "Low A", "The Tones", 214), file(2, "Rising Fifth", "The Tones", 187), file(3, "High C", "The Tones", 243),
                    file(4, "Quiet Interval", "The Tones", 198), file(5, "Overtone", "The Tones", 256), file(6, "Beat Frequency", "The Tones", 175)]
        phase = .editing
        type = .audio
        skipped = 0
        madeFolders = []
        switch page {
        case .empty:
            items = []
            sourceFolder = nil
            deviceState = FixtureBurner.blankCD()
        case .folders:
            type = .data
            items = list.enumerated().map { index, item in
                var placed = item
                placed.folder = index < 2 ? "Slow Pieces" : index < 5 ? "Slow Pieces/Evening" : ""
                return placed
            }
            items[5].url = URL(fileURLWithPath: "/Music/Mix/06 Beat Frequency.m4a")
            madeFolders = ["Favorites"]
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = FixtureBurner.blankDVD()
        case .list:
            items = list
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = FixtureBurner.blankCD()
        case .noDisc:
            items = list
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = .noDisc
        case .over:
            items = list + (7...20).map { file($0, "Long Piece \($0)", "The Tones", 330) }
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = FixtureBurner.blankCD()
        case .videoList, .videoOver:
            type = .video
            items = []
            deviceState = FixtureBurner.blankDVD()
        case .videoEmpty:
            type = .video
            items = []
            sourceFolder = nil
            deviceState = FixtureBurner.blankDVD()
        case .dvd:
            items = list
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = FixtureBurner.blankDVD()
        case .burning:
            items = list
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = FixtureBurner.blankCD()
            phase = .burning(.burning(0.4))
        case .done:
            items = list
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = .noDisc
            phase = .done
        case .failed:
            items = list
            sourceFolder = URL(fileURLWithPath: "/Music/Mix", isDirectory: true)
            deviceState = FixtureBurner.blankCD()
            phase = .failed(BurnError.driveError("The disc could not be written.").localizedDescription)
        }
    }
}

enum BurnSnapshotPage: String, CaseIterable {
    case empty, list, folders, noDisc, over, dvd, burning, done, failed, videoEmpty, videoList, videoOver
}
