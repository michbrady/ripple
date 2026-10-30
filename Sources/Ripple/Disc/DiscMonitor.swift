import DiskArbitration
import Foundation

/// Watches for discs through DiskArbitration. While Ripple runs it also refuses
/// the system's mount of audio discs, so Music does not open and nothing else
/// holds the disc; Ripple reads the raw device instead.
final class DiscMonitor {
    var onInsert: ((_ bsdName: String) -> Void)?
    var onRemove: ((_ bsdName: String) -> Void)?

    private let session: DASession
    private var disks: [String: DADisk] = [:]

    init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let cdMedia = [
            kDADiskDescriptionMediaWholeKey as String: true,
            kDADiskDescriptionMediaKindKey as String: "IOCDMedia",
        ] as CFDictionary

        DARegisterDiskAppearedCallback(session, cdMedia, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.disks[name] = disk
                monitor.onInsert?(name)
            }
        }, context)

        DARegisterDiskDisappearedCallback(session, cdMedia, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.disks[name] = nil
                monitor.onRemove?(name)
            }
        }, context)

        let audioVolume = [kDADiskDescriptionVolumeKindKey as String: "cddafs"] as CFDictionary
        DARegisterDiskMountApprovalCallback(session, audioVolume, { _, _ in
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
                                              "Ripple reads audio discs directly" as CFString)
            return Unmanaged.passRetained(dissenter)
        }, nil)

        DASessionSetDispatchQueue(session, DispatchQueue.main)
    }

    func eject(bsdName: String) {
        guard let disk = disks[bsdName] else { return }
        DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
    }
}
