import AppKit
import Foundation
import Observation
import RippleKit

enum AppMode: String, CaseIterable, Identifiable {
    case rip, burn

    var id: String { rawValue }
    var title: String { self == .rip ? "Rip" : "Burn" }
}

/// Burn mode: a folder of MP3 files, the disc type, the blank disc, and the burn itself.
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
    private(set) var sourceFolder: URL?
    /// Files left out of the list: not MP3, or not readable as audio.
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
        if case .ready = deviceState { return true }
        return false
    }

    var canBurn: Bool { phase == .editing && isReady && fit == .fits }

    /// One line about the drive and the disc in it.
    var deviceLine: String {
        switch deviceState {
        case .noDrive: "Connect a USB burner to burn a disc."
        case .noDisc: type == .audio ? "Insert a blank CD-R." : "Insert a blank CD-R or DVD-R."
        case .notBlank(let label, let rewritable):
            rewritable ? "This \(label) is not blank. Erase it in Disk Utility, then insert it again."
                       : "This \(label) is not blank. Insert a blank disc."
        case .ready(let media): "\(deviceName) · blank \(media.label)"
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
        panel.message = "Choose a folder of MP3 files to burn"
        if let sourceFolder { panel.directoryURL = sourceFolder } else { panel.directoryURL = URL.musicDirectory }
        if panel.runModal() == .OK, let url = panel.url { load(folder: url) }
    }

    func load(folder: URL) {
        isScanning = true
        sourceFolder = folder
        Task {
            let scan = await BurnScanner.scan(folder)
            items = scan.items
            skipped = scan.skipped
            isScanning = false
            phase = .editing
        }
    }

    /// Adds dropped files and folders to the list. Files already listed are not added twice.
    func add(dropped urls: [URL]) async {
        isScanning = true
        let scan = await BurnScanner.scan(dropped: urls)
        let known = Set(items.map(\.id))
        items += scan.items.filter { !known.contains($0.id) }
        skipped += scan.skipped
        if sourceFolder == nil, urls.count == 1 { sourceFolder = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent() }
        isScanning = false
        phase = .editing
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = items
        items.removeAll { ids.contains($0.id) }
        undoManager?.registerUndo(withTarget: self) { model in model.restore(before) }
        undoManager?.setActionName(ids.count == 1 ? "Remove File" : "Remove \(ids.count) Files")
    }

    func move(from source: IndexSet, to destination: Int) {
        let before = items
        items.move(fromOffsets: source, toOffset: destination)
        undoManager?.registerUndo(withTarget: self) { model in model.restore(before) }
        undoManager?.setActionName("Reorder Files")
    }

    private func restore(_ list: [BurnItem]) {
        let current = items
        items = list
        undoManager?.registerUndo(withTarget: self) { model in model.restore(current) }
    }

    func clear() {
        items = []
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
        let job = BurnJob(type: type, files: items.map(\.url), volumeName: volumeName)
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
        switch page {
        case .empty:
            items = []
            sourceFolder = nil
            deviceState = FixtureBurner.blankCD()
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
    case empty, list, noDisc, over, dvd, burning, done, failed
}
