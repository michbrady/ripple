import DiscRecording
import Foundation
import RippleKit

/// The Mac's burner, through Apple's DiscRecording framework.
///
/// Status is read the way `drutil` and System Information do. The write path (`burn`) has been
/// checked against the framework's API but not yet run on a real blank disc: see docs/STORIES.md S-031.
final class DiscRecordingBurner: DiscBurner, @unchecked Sendable {
    /// What the drive does when the burn finishes. The app ejects; a test that reads the disc back mounts it.
    enum Completion: Sendable { case eject, mount }

    private let completion: Completion

    init(completion: Completion = .eject) {
        self.completion = completion
    }

    /// The first optical drive that can write discs.
    private func device() -> DRDevice? {
        let devices = DRDevice.devices() as? [DRDevice] ?? []
        return devices.first { device in
            let info = device.info() as? [String: Any] ?? [:]
            let write = info[DRDeviceWriteCapabilitiesKey] as? [String: Any] ?? [:]
            return [DRDeviceCanWriteCDRKey, DRDeviceCanWriteDVDRKey, DRDeviceCanWriteBDKey].contains { (write[$0] as? Bool) == true }
        }
    }

    var deviceName: String? { device()?.displayName() }

    func state() -> BurnDeviceState {
        guard let device = device() else { return .noDrive }
        let status = device.status() as? [String: Any] ?? [:]
        guard (status[DRDeviceMediaStateKey] as? String) == DRDeviceMediaStateMediaPresent else { return .noDisc }
        let media = status[DRDeviceMediaInfoKey] as? [String: Any] ?? [:]
        let label = Self.label(media[DRDeviceMediaTypeKey] as? String)
        guard (media[DRDeviceMediaIsBlankKey] as? Bool) == true else {
            return .notBlank(label: label, rewritable: (media[DRDeviceMediaIsOverwritableKey] as? Bool) == true)
        }
        let kind: BurnMedia.Kind = switch media[DRDeviceMediaClassKey] as? String {
        case DRDeviceMediaClassCD: .cd
        case DRDeviceMediaClassDVD: .dvd
        case DRDeviceMediaClassBD: .bluray
        default: .other
        }
        return .ready(BurnMedia(kind: kind, label: label, blocksFree: (media[DRDeviceMediaBlocksFreeKey] as? Int) ?? 0))
    }

    /// "DRDeviceMediaTypeDVDR" becomes "DVD-R".
    static func label(_ type: String?) -> String {
        switch type {
        case DRDeviceMediaTypeCDR: "CD-R"
        case DRDeviceMediaTypeCDRW: "CD-RW"
        case DRDeviceMediaTypeDVDR: "DVD-R"
        case DRDeviceMediaTypeDVDRW: "DVD-RW"
        case DRDeviceMediaTypeDVDPlusR: "DVD+R"
        case DRDeviceMediaTypeDVDPlusRW: "DVD+RW"
        case DRDeviceMediaTypeDVDRAM: "DVD-RAM"
        case DRDeviceMediaTypeBDR: "BD-R"
        case DRDeviceMediaTypeBDRE: "BD-RE"
        case .some(let other): other.replacingOccurrences(of: "DRDeviceMediaType", with: "disc")
        case nil: "disc"
        }
    }

    /// Checks the drive every second and announces a change, which is all the window needs.
    func stateChanges() -> AsyncStream<BurnDeviceState> {
        AsyncStream { continuation in
            let watcher = Task {
                var last = state()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let now = state()
                    if now != last {
                        last = now
                        continuation.yield(now)
                    }
                }
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }

    func eject() {
        Task { @MainActor in _ = device()?.ejectMedia() }
    }

    func burn(_ job: BurnJob, progress: @Sendable (BurnStage) -> Void) async throws {
        try await Self.run(job, completion: completion, progress: progress, device: { self.device() })
    }

    @MainActor
    private static func run(_ job: BurnJob, completion: Completion, progress: @Sendable (BurnStage) -> Void, device: () -> DRDevice?) async throws {
        progress(.preparing)
        guard let device = device() else { throw BurnError.noDisc }
        let layout: Any
        var workFolder: URL?
        defer { if let workFolder { try? FileManager.default.removeItem(at: workFolder) } }
        switch job.type {
        case .audio:
            layout = job.files.compactMap { DRTrack(forAudioFile: $0.path) }
        case .data:
            // M4A files become MP3 in a work folder first. Cancel still works: nothing is written yet.
            let prepared = try await DiscPreparer.prepare(DiscLayout.entries(for: job))
            workFolder = prepared.workFolder
            let root = DRFolder(name: String(job.volumeName.prefix(32)))!
            var folders: [String: DRFolder] = ["": root]
            for path in DiscLayout.allFolders(items: [], made: job.folders + prepared.entries.map(\.folder)) {
                guard let made = DRFolder(name: DiscLayout.name(of: path)) else { continue }
                folders[DiscLayout.parent(of: path)]?.addChild(made)
                folders[path] = made
            }
            for entry in prepared.entries {
                guard let item = DRFile(path: entry.source.path) else { continue }
                // The number keeps the list order on players that play files by name.
                item.setBaseName(entry.name)
                (folders[entry.folder] ?? root).addChild(item)
            }
            layout = DRTrack(forRootFolder: root) as Any
        case .video, .bluray:
            // The finished disc image, written as it is. Nothing is prepared, so Cancel works until writing starts.
            guard let image = job.files.first, let imageLayout = DRBurn.layout(forImageFile: image.path) else {
                throw BurnError.discRejected("The disc image could not be read.")
            }
            layout = imageLayout
        }
        guard let burn = DRBurn(device: device) else { throw BurnError.noDisc }
        burn.setProperties([
            DRBurnCompletionActionKey: completion == .eject ? DRBurnCompletionActionEject : DRBurnCompletionActionMount,
            DRBurnVerifyDiscKey: true,
            DRBurnAppendableKey: false,
        ])
        burn.writeLayout(layout)

        // RIPPLE_BURN_DEBUG=1 logs every state the framework reports, to learn how a real burn proceeds.
        let debug = ProcessInfo.processInfo.environment["RIPPLE_BURN_DEBUG"] == "1"
        var lastLogged = ""
        var writing = false
        while true {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled {
                burn.abort()
                throw CancellationError()
            }
            let status = burn.status() as? [String: Any] ?? [:]
            let percent = (status[DRStatusPercentCompleteKey] as? Double) ?? 0
            if debug {
                let line = "\(status[DRStatusStateKey] as? String ?? "nil") \(Int(percent * 100))%"
                if line != lastLogged {
                    lastLogged = line
                    FileHandle.standardError.write(Data("BURN \(line)\n".utf8))
                }
            }
            switch status[DRStatusStateKey] as? String {
            case DRStatusStateDone:
                return
            case DRStatusStateFailed:
                let error = status[DRErrorStatusKey] as? [String: Any]
                throw BurnError.driveError((error?[DRErrorStatusErrorStringKey] as? String) ?? "The burn did not finish.")
            case DRStatusStateTrackOpen, DRStatusStateTrackWrite, DRStatusStateTrackClose, DRStatusStateVerifying:
                writing = true
                progress(.burning(max(0, min(1, percent))))
            case DRStatusStateSessionClose, DRStatusStateFinishing:
                progress(.finishing)
            default:
                progress(writing ? .burning(max(0, min(1, percent))) : .preparing)
            }
        }
    }
}
