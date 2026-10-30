import AppKit
import Foundation
import Observation
import RippleKit

/// The pages snapshot mode visits.
enum SnapshotPage: String, CaseIterable {
    case empty, tracks, unmatched, picker, ripping, done, attention
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
    /// The Cover as JPEG or PNG bytes, written into every ripped file.
    private(set) var coverData: Data?
    var isCancelling = false
    /// Settings reopens on the last tab.
    var settingsTab: SettingsTab = .general {
        didSet { defaults.set(settingsTab.rawValue, forKey: "settings.tab") }
    }
    var outputFolder: URL = URL.musicDirectory {
        didSet { defaults.set(outputFolder.path, forKey: "outputFolder") }
    }
    /// MP3 or M4A. MP3 unless the user chooses otherwise.
    var format: RipFormat = .mp3 {
        didSet { defaults.set(format.rawValue, forKey: "format") }
    }
    var mp3Quality: MP3Encoder.Quality = .vbr(2) {
        didSet { defaults.set(mp3Quality.rawValue, forKey: "mp3.quality") }
    }
    /// Read every part of the disc until two reads agree. Slower, and it catches bad data.
    var verifyReads = true {
        didSet { defaults.set(verifyReads, forKey: "verifyReads") }
    }

    /// Saved settings live here. Test and snapshot runs get their own store, never the real one.
    let defaults: UserDefaults

    private(set) var disc: (any AudioDisc)?
    private var bsdName: String?
    var lookup: any AlbumLookup = LiveLookup()
    private var lookupTask: Task<Void, Never>?
    private var customCover = false
    private let monitor = DiscMonitor()
    private var ripWork: Task<[URL], Error>?
    /// The file each ripped track went to, so Retry can replace it.
    private var trackFiles: [Int: URL] = [:]
    /// Set while one track is being ripped again: where to go back to if that is cancelled.
    private var resumePhase: Phase?
    private var resumeStatus: (id: Int, status: TrackRow.Status)?
    private var ripFinished: Task<Void, Never>?

    init(defaults: UserDefaults = Store.defaults) {
        self.defaults = defaults
        Self.current = self
        // Setting properties inside init does not save them again.
        settingsTab = SettingsTab(rawValue: defaults.string(forKey: "settings.tab") ?? "") ?? .general
        if let path = defaults.string(forKey: "outputFolder") { outputFolder = URL(fileURLWithPath: path, isDirectory: true) }
        format = RipFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .mp3
        mp3Quality = MP3Encoder.Quality(rawValue: defaults.string(forKey: "mp3.quality") ?? "") ?? .vbr(2)
        verifyReads = defaults.object(forKey: "verifyReads") as? Bool ?? true
    }

    // MARK: Disc

    var hasDisc: Bool { disc != nil }
    var isRipping: Bool { phase == .ripping }
    var checkedCount: Int { rows.filter(\.include).count }
    var rippedCount: Int { rows.filter { if case .done = $0.status { true } else if case .needsAttention = $0.status { true } else { false } }.count }
    var needsAttentionCount: Int { rows.filter { if case .needsAttention = $0.status { true } else { false } }.count }
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
        setCoverData(nil)
        customCover = false
    }

    private func setCoverData(_ data: Data?) {
        coverData = data
        coverImage = data.flatMap { NSImage(data: $0) }
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
                guard let data = await source.cover(for: match), selectedMatchID == match.id, !customCover,
                      let prepared = CoverPrep.prepared(data) else { return }
                setCoverData(prepared)
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
        guard let data = try? Data(contentsOf: url), let prepared = CoverPrep.prepared(data) else { return false }
        setCoverData(prepared)
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

    func rip() { startRip(only: nil) }

    /// Rips one track again, replacing its file. Used for a track marked Needs Attention.
    func retry(_ id: Int) {
        guard !isRipping, case .done = phase, let row = rows.first(where: { $0.id == id }) else { return }
        resumePhase = phase
        resumeStatus = (id, row.status)
        startRip(only: id)
    }

    private func startRip(only target: Int?) {
        guard let disc, target != nil || phase == .ready, target != nil || checkedCount > 0 else { return }
        let toc = disc.toc
        let byIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let tracks = toc.entries.indices.map { index -> RipTrack in
            guard let row = byIndex[index] else { return RipTrack(number: toc.entries[index].number, title: "", include: false) }
            return RipTrack(number: row.number, title: row.title, artist: row.artist, include: target.map { $0 == index } ?? row.include)
        }
        var request = RipRequest(disc: disc, tracks: tracks, albumArtist: albumArtist, album: albumTitle,
                                 folder: outputFolder, quality: mp3Quality, format: format,
                                 year: albumYear, cover: coverData, verify: verifyReads,
                                 discNumber: discNumber, discCount: discCount, isCompilation: isCompilation)
        if let target {
            if let file = trackFiles[target] { request.replacing = [target: file] }
            update(target) { $0.status = .waiting }
        } else {
            trackFiles = [:]
            for index in rows.indices { rows[index].status = .waiting }
        }
        isCancelling = false
        phase = .ripping
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            try await Ripper.rip(request) { event in
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
            update(track) { row in
                switch row.status {
                case .waiting, .ripping: row.status = .ripping(fraction)
                case .done, .needsAttention: break
                }
            }
        case .finished(let track, let file):
            trackFiles[track] = file
            update(track) { $0.status = .done }
        case .needsAttention(let track, let unreadable, let suspect):
            update(track) { $0.status = .needsAttention(unreadable: unreadable, suspect: suspect) }
        }
    }

    private func update(_ id: Int, _ change: (inout TrackRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    private func finishRip(_ result: Result<[URL], Error>) {
        ripWork = nil
        isCancelling = false
        let resume = resumePhase
        let resumeStatus = resumeStatus
        resumePhase = nil
        self.resumeStatus = nil
        guard disc != nil else { return }
        switch result {
        case .success(let files):
            phase = .done(folder: files.first?.deletingLastPathComponent() ?? doneFolder(resume))
        case .failure(let error):
            for index in rows.indices {
                if case .ripping = rows[index].status { rows[index].status = .waiting }
            }
            if let resume, let resumeStatus {
                // A cancelled or failed Retry puts the track back as it was.
                update(resumeStatus.id) { $0.status = resumeStatus.status }
                phase = error is CancellationError ? resume : .failed("Ripple stopped: \(error.localizedDescription)")
            } else if error is CancellationError {
                phase = .ready
            } else {
                phase = .failed("Ripple stopped: \(error.localizedDescription)")
            }
        }
    }

    private func doneFolder(_ phase: Phase?) -> URL? {
        if case .done(let folder)? = phase { return folder }
        return nil
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
            setCoverData(nil)
            customCover = false
            lookupState = .notFound
            return
        }
        matches = FixtureLookup.albums(trackCount: rows.count)
        lookupState = .found
        apply(matches[0])
        setCoverData(FixtureLookup.coverPNG())
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
        case .attention:
            for index in rows.indices { rows[index].status = .done }
            rows[2].status = .needsAttention(unreadable: 3, suspect: 0)
            rows[5].status = .needsAttention(unreadable: 0, suspect: 2)
            phase = .done(folder: outputFolder.appending(path: "The Tones/Sine Waves", directoryHint: .isDirectory))
        default:
            break
        }
    }
}
