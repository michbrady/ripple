import AppKit
import Foundation
import RippleKit

/// After Ripple is dragged to Applications and opened, the installer disk image is usually still open. This offers
/// to eject it and move the .dmg to the Trash. It asks only when it can see that image: macOS says which file an open
/// image came from, so Ripple never has to search your Downloads folder (which would make macOS ask for access).
@MainActor
struct InstallerCleanup {
    var images: @Sendable () -> [MountedImage] = { InstallerCleanup.runningImages() }
    /// Is this volume Ripple's own installer? It holds a Ripple.app with this app's identifier.
    var isInstallerVolume: @Sendable (URL) -> Bool = { InstallerCleanup.holdsThisApp($0) }
    /// Asks the user. Returns true for "Move to Trash".
    var ask: (InstallerLeftover) -> Bool = { InstallerCleanup.askWithAlert($0) }
    var eject: (URL) throws -> Void = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) }
    var trash: (URL) async throws -> URL? = { try await InstallerCleanup.recycle($0) }
    var defaults: UserDefaults = Store.defaults

    enum Outcome: Equatable {
        case notInstalled, nothingToClean, declined, trashed(URL?), ejectedButNotTrashed(String)
    }

    private static let declinedKey = "installer.declined"

    /// Where the app has to be for this to run: Applications, or ~/Applications.
    static func isInstalledLocation(_ bundle: URL) -> Bool {
        let path = bundle.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Offers once per installer file. Quiet when the app is not installed, when no installer is open, or when the
    /// user already said Keep for this file.
    @discardableResult
    func offer(installedAt bundle: URL = Bundle.main.bundleURL) async -> Outcome {
        guard Self.isInstalledLocation(bundle) else { return .notInstalled }
        let open = images
        let isInstaller = isInstallerVolume
        let leftover = await Task.detached { InstallerLeftover.find(in: open(), isInstaller: isInstaller) }.value
        guard let leftover else { return .nothingToClean }
        let declined = defaults.stringArray(forKey: Self.declinedKey) ?? []
        guard !declined.contains(leftover.image.path) else { return .declined }
        guard ask(leftover) else {
            defaults.set(declined + [leftover.image.path], forKey: Self.declinedKey)
            return .declined
        }
        // The same file opened twice is mounted twice: eject every copy.
        for volume in leftover.volumes {
            do {
                try eject(volume)
            } catch {
                return .ejectedButNotTrashed("The installer could not be ejected: \(error.localizedDescription)")
            }
        }
        do {
            return .trashed(try await trash(leftover.image))
        } catch {
            return .ejectedButNotTrashed("The installer was ejected, but \(leftover.image.lastPathComponent) could not be moved to the Trash: \(error.localizedDescription)")
        }
    }

    // MARK: The real pieces

    nonisolated static func runningImages() -> [MountedImage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return MountedImage.parse(data)
    }

    nonisolated static func holdsThisApp(_ volume: URL) -> Bool {
        let info = volume.appending(path: "Ripple.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
    }

    static func askWithAlert(_ leftover: InstallerLeftover) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Ripple is installed."
        alert.informativeText = "The installer, \u{201C}\(leftover.image.lastPathComponent)\u{201D}, is still open. You do not need it now. Move it to the Trash? This also ejects it."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Moves a file to the Trash. Returns where it went.
    static func recycle(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { moved, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: moved[url]) }
            }
        }
    }
}
