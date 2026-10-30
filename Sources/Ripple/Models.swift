import AppKit
import Foundation
import Observation
import RippleKit

/// One track on screen.
struct TrackRow: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case ripping(Double)
        case done
    }

    /// The index in the disc's table of contents.
    var id: Int
    var number: Int
    var title: String
    var artist: String
    var seconds: Double
    var include = true
    var status: Status = .waiting
}

/// The pages snapshot mode visits.
enum SnapshotPage: String, CaseIterable {
    case empty, tracks, ripping, done
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case empty
        case reading
        case ready
        case ripping
        case done(folder: URL?)
        case failed(String)
    }

    /// The window that is up, for the quit prompt.
    static weak var current: AppModel?

    var phase: Phase = .empty
    var rows: [TrackRow] = []
    var albumTitle = "Unknown Album"
    var albumArtist = "Unknown Artist"
    var isCancelling = false
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }
    var outputFolder: URL = {
        if !Store.isOverridden, let path = UserDefaults.standard.string(forKey: "outputFolder") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL.musicDirectory
    }() {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(outputFolder.path, forKey: "outputFolder") } }
    }

    private(set) var disc: (any AudioDisc)?
    private var bsdName: String?
    private let monitor = DiscMonitor()
    private var ripWork: Task<[URL], Error>?
    private var ripFinished: Task<Void, Never>?

    init() {
        Self.current = self
    }

    // MARK: Disc

    var hasDisc: Bool { disc != nil }
    var isRipping: Bool { phase == .ripping }
    var checkedCount: Int { rows.filter(\.include).count }
    var totalSeconds: Double { rows.reduce(0) { $0 + $1.seconds } }

    var windowTitle: String {
        hasDisc && albumTitle != "Unknown Album" ? albumTitle : "Ripple"
    }

    /// Starts watching for discs. APP_FIXTURE_DISC=1 loads a made-up disc instead.
    func start() {
        if ProcessInfo.processInfo.environment["APP_FIXTURE_DISC"] == "1" {
            load(FixtureDisc(), bsdName: nil)
            return
        }
        guard let monitor else { return }
        monitor.onInsert = { [weak self] name in self?.discInserted(bsdName: name) }
        monitor.onRemove = { [weak self] name in self?.discRemoved(bsdName: name) }
        monitor.start()
    }

    private func discInserted(bsdName name: String) {
        guard !isRipping else { return }
        phase = .reading
        Task {
            do {
                let disc = try await Task.detached { try DeviceDisc(bsdName: name) }.value
                load(disc, bsdName: name)
            } catch {
                disc = nil
                bsdName = name
                phase = .failed("Ripple cannot read this disc.")
            }
        }
    }

    private func discRemoved(bsdName name: String) {
        guard name == bsdName else { return }
        if isRipping { cancel() }
        clear()
    }

    /// Shows a disc: one row per audio track, titled "Track 01" until a lookup or an edit renames it.
    func load(_ disc: any AudioDisc, bsdName: String?) {
        let toc = disc.toc
        guard !toc.audioTracks.isEmpty else {
            self.disc = nil
            self.bsdName = bsdName
            phase = .failed("This is not an audio disc.")
            return
        }
        self.disc = disc
        self.bsdName = bsdName
        albumTitle = "Unknown Album"
        albumArtist = "Unknown Artist"
        rows = toc.entries.enumerated().compactMap { index, entry in
            guard entry.isAudio else { return nil }
            return TrackRow(id: index, number: entry.number, title: String(format: "Track %02d", entry.number),
                            artist: "", seconds: toc.seconds(ofTrack: index))
        }
        phase = .ready
    }

    func eject() {
        if isRipping { cancel() }
        if let bsdName { monitor?.eject(bsdName: bsdName) }
        clear()
    }

    private func clear() {
        disc = nil
        bsdName = nil
        rows = []
        albumTitle = "Unknown Album"
        albumArtist = "Unknown Artist"
        phase = .empty
    }

    // MARK: Output Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = "Choose"
        panel.message = "Choose where ripped albums are saved"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    // MARK: Rip

    func rip() {
        guard let disc, phase == .ready, checkedCount > 0 else { return }
        let toc = disc.toc
        let byIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let tracks = toc.entries.indices.map { index -> RipTrack in
            guard let row = byIndex[index] else { return RipTrack(number: toc.entries[index].number, title: "", include: false) }
            return RipTrack(number: row.number, title: row.title, artist: row.artist, include: row.include)
        }
        let request = RipRequest(disc: disc, tracks: tracks, albumArtist: albumArtist, album: albumTitle,
                                 folder: outputFolder, quality: .vbr(2))
        for index in rows.indices { rows[index].status = .waiting }
        isCancelling = false
        phase = .ripping
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            try Ripper.rip(request) { event in
                Task { @MainActor in self?.handle(event) }
            }
        }
        ripWork = work
        ripFinished = Task { [weak self] in
            let result = await work.result
            self?.finishRip(result)
        }
    }

    func cancel() {
        guard isRipping else { return }
        isCancelling = true
        ripWork?.cancel()
    }

    private func handle(_ event: RipEvent) {
        switch event {
        case .started(let track):
            update(track) { $0.status = .ripping(0) }
        case .progress(let track, let fraction):
            update(track) { if $0.status != .done { $0.status = .ripping(fraction) } }
        case .finished(let track, _):
            update(track) { $0.status = .done }
        }
    }

    private func update(_ id: Int, _ change: (inout TrackRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    private func finishRip(_ result: Result<[URL], Error>) {
        ripWork = nil
        isCancelling = false
        guard disc != nil else { return }
        switch result {
        case .success(let files):
            phase = .done(folder: files.first?.deletingLastPathComponent())
        case .failure(let error):
            for index in rows.indices {
                if case .ripping = rows[index].status { rows[index].status = .waiting }
            }
            if error is CancellationError {
                phase = .ready
            } else {
                phase = .failed("Ripple stopped: \(error.localizedDescription)")
            }
        }
    }

    /// Lets a rip finish its clean-up after a cancel. Used when the app quits.
    func stopRipping() async {
        cancel()
        await ripFinished?.value
    }

    func rippedAnother() { eject() }

    // MARK: Snapshot pages

    /// Puts the window in the state a snapshot page shows, on a made-up disc.
    func showSnapshot(_ page: SnapshotPage) {
        switch page {
        case .empty:
            clear()
        case .tracks, .ripping, .done:
            if disc == nil || bsdName != nil || rows.count != 8 {
                load(FixtureDisc(trackSeconds: [214, 187, 243, 198, 256, 175, 221, 309]), bsdName: nil)
            }
            for index in rows.indices { rows[index].status = .waiting }
            phase = .ready
            if page == .ripping {
                for index in rows.indices {
                    rows[index].status = index < 3 ? .done : index == 3 ? .ripping(0.4) : .waiting
                }
                phase = .ripping
            } else if page == .done {
                for index in rows.indices { rows[index].status = .done }
                phase = .done(folder: outputFolder.appending(path: "Unknown Artist/Unknown Album", directoryHint: .isDirectory))
            }
        }
    }
}
