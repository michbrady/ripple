import AppKit
import Foundation
import Observation
import RippleKit

/// The pages snapshot mode visits.
enum SnapshotPage: String, CaseIterable {
    case empty, tracks, unmatched, picker, ripping, done
}

/// How the album lookup went.
enum LookupState: Equatable {
    case idle, searching, found, notFound, offline
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
    /// The album as shown: what the lookup found merged with what the user typed (RippleKit/AlbumDraft.swift).
    var album = AlbumDraft()
    var matches: [AlbumMatch] = []
    var lookupState: LookupState = .idle
    var isPickingMatch = false
    var coverImage: NSImage?
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
    var lookup: any AlbumLookup = LiveLookup()
    private var lookupTask: Task<Void, Never>?
    private var customCover = false
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
        hasDisc && !albumTitle.isEmpty ? albumTitle : "Ripple"
    }

    var isCompilation: Bool { album.isCompilation }
    var rows: [TrackRow] {
        get { album.tracks }
        set { album.tracks = newValue }
    }
    var albumTitle: String { album.title }
    var albumArtist: String { album.artist }
    var albumYear: String { album.year }
    var discNumber: Int { album.discNumber }
    var discCount: Int { album.discCount }
    var selectedMatchID: String? { album.selectedMatchID }

    /// Starts watching for discs. APP_FIXTURE_DISC=1 loads a made-up disc instead.
    func start() {
        if ProcessInfo.processInfo.environment["APP_FIXTURE_DISC"] == "1" {
            lookup = FixtureLookup()
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
        resetAlbum()
        rows = toc.entries.enumerated().compactMap { index, entry in
            guard entry.isAudio else { return nil }
            return TrackRow(id: index, number: entry.number, title: String(format: "Track %02d", entry.number),
                            artist: "", seconds: toc.seconds(ofTrack: index))
        }
        phase = .ready
        startLookup()
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
        resetAlbum()
        phase = .empty
    }

    private func resetAlbum() {
        lookupTask?.cancel()
        album = AlbumDraft()
        matches = []
        lookupState = .idle
        isPickingMatch = false
        coverImage = nil
        customCover = false
    }

    // MARK: Album lookup

    private func startLookup() {
        guard let disc else { return }
        lookupTask?.cancel()
        lookupState = .searching
        let source = lookup
        let toc = disc.toc
        lookupTask = Task {
            do {
                let found = try await source.matches(for: toc)
                if Task.isCancelled { return }
                matches = found
                guard let best = found.first else {
                    lookupState = .notFound
                    return
                }
                lookupState = .found
                apply(best)
            } catch {
                if !Task.isCancelled { lookupState = .offline }
            }
        }
    }

    /// Fills the album and track titles from a match, and fetches its cover. Anything the user typed stays.
    func apply(_ match: AlbumMatch) {
        album.apply(match)
        if !customCover {
            let source = lookup
            Task {
                guard let data = await source.cover(for: match), selectedMatchID == match.id, !customCover else { return }
                coverImage = NSImage(data: data)
            }
        }
    }

    func chooseMatch(id: String) {
        guard let match = matches.first(where: { $0.id == id }) else { return }
        apply(match)
    }

    // MARK: Edits

    func setAlbumTitle(_ text: String) { album.setTitle(text) }
    func setAlbumArtist(_ text: String) { album.setArtist(text) }
    func setTitle(_ text: String, row id: Int) { album.setTrackTitle(text, id: id) }
    func setArtist(_ text: String, row id: Int) { album.setTrackArtist(text, id: id) }

    /// Uses a picture from a file as the Cover. Returns false when the file is not an image.
    @discardableResult
    func setCover(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url), image.isValid else { return false }
        coverImage = image
        customCover = true
        return true
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
                                 folder: outputFolder, quality: .vbr(2),
                                 discNumber: discNumber, discCount: discCount, isCompilation: isCompilation)
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

    /// Puts the window in the state a snapshot page shows, on a made-up disc and album.
    func showSnapshot(_ page: SnapshotPage) {
        if page == .empty {
            clear()
            return
        }
        lookup = FixtureLookup()
        let toc = FixtureDisc(trackSeconds: [214, 187, 243, 198, 256, 175, 221, 309]).toc
        if disc?.toc != toc {
            load(FixtureDisc(trackSeconds: [214, 187, 243, 198, 256, 175, 221, 309]), bsdName: nil)
        }
        lookupTask?.cancel()
        isPickingMatch = false
        for index in rows.indices { rows[index].status = .waiting }
        phase = .ready
        if page == .unmatched {
            album.clearDetails()
            matches = []
            coverImage = nil
            customCover = false
            lookupState = .notFound
            return
        }
        matches = FixtureLookup.albums(trackCount: rows.count)
        lookupState = .found
        apply(matches[0])
        coverImage = NSImage(data: FixtureLookup.coverPNG())
        switch page {
        case .picker:
            isPickingMatch = true
        case .ripping:
            for index in rows.indices {
                rows[index].status = index < 3 ? .done : index == 3 ? .ripping(0.4) : .waiting
            }
            phase = .ripping
        case .done:
            for index in rows.indices { rows[index].status = .done }
            phase = .done(folder: outputFolder.appending(path: "The Tones/Sine Waves", directoryHint: .isDirectory))
        default:
            break
        }
    }
}
