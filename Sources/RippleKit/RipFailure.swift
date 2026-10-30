import Foundation

/// Plain words for a rip that stopped: what happened, and what to do.
public struct RipFailure: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Read the disc again.
        case tryAgain
        /// The Output Folder is the problem: choose another.
        case chooseFolder
        /// Nothing to do with this disc.
        case eject
    }

    public var message: String
    public var action: Action

    public init(message: String, action: Action) {
        self.message = message
        self.action = action
    }

    /// The failure for an error thrown while ripping into `folder`.
    public static func describing(_ error: Error, folder: URL) -> RipFailure {
        let name = "\u{201C}\(folder.lastPathComponent)\u{201D}"
        switch Self.problem(error) {
        case .diskFull:
            return RipFailure(message: "The disk is full, so Ripple cannot save to \(name). Free some space or choose another Output Folder.",
                              action: .chooseFolder)
        case .notWritable:
            return RipFailure(message: "Ripple cannot save to \(name). The folder is not writable. Choose another Output Folder.",
                              action: .chooseFolder)
        case .missing:
            return RipFailure(message: "The folder \(name) is missing. Choose another Output Folder.", action: .chooseFolder)
        case .other:
            return RipFailure(message: "Unable to finish ripping. \(error.localizedDescription)", action: .tryAgain)
        }
    }

    enum Problem { case diskFull, notWritable, missing, other }

    /// Looks at the error and the POSIX error under it.
    static func problem(_ error: Error) -> Problem {
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSCocoaErrorDomain {
                switch CocoaError.Code(rawValue: ns.code) {
                case .fileWriteOutOfSpace: return .diskFull
                case .fileWriteNoPermission, .fileWriteVolumeReadOnly: return .notWritable
                case .fileNoSuchFile, .fileWriteInvalidFileName: return .missing
                default: break
                }
            } else if ns.domain == NSPOSIXErrorDomain {
                switch Int32(ns.code) {
                case ENOSPC, EDQUOT: return .diskFull
                case EACCES, EPERM, EROFS: return .notWritable
                case ENOENT, ENOTDIR: return .missing
                default: break
                }
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .other
    }
}
