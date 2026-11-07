import AppKit
import RippleKit
import SwiftUI

// Ripple
//   Ripple                      the app
//   APP_STORE=<file> Ripple     run without touching your saved settings (tests, snapshots)
//   APP_SNAPSHOT=<dir> Ripple   save a PNG of every page and Settings tab in light and dark mode, then quit
//   APP_FIXTURE_DISC=1 Ripple   open a made-up disc of tones instead of waiting for a drive
//   Ripple --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Ripple      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Ripple           draw the 8 pt grid and the layout probes over the window

@main
struct RippleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var burn = BurnModel(burner: Burners.make())
    @State private var dvd = DVDModel()

    var body: some Scene {
        Window("Ripple", id: "main") {
            ContentView()
                .environment(model)
                .environment(burn)
                .environment(dvd)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 760, height: 560)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Ripple Website") { NSWorkspace.shared.open(AppLinks.website) }
                Button("Privacy and Terms") { NSWorkspace.shared.open(AppLinks.privacy) }
                Divider()
                Button("Leave a Tip on Ko-fi") { NSWorkspace.shared.open(AppLinks.tip) }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Ripple") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Rip Checked Tracks") { model.mode = .rip; model.rip() }
                    .keyboardShortcut("r")
                    .disabled(model.mode == .burn || model.phase != .ready || model.checkedCount == 0)
                Button("Burn Disc") { burn.burn() }
                    .keyboardShortcut("b")
                    .disabled(model.mode == .rip || !burn.canBurn)
                Button("Eject Disc") { model.mode == .burn ? burn.eject() : model.eject() }
                    .keyboardShortcut("e")
                    .disabled(model.mode == .burn ? burn.isBusy : !model.hasDisc)
            }
            CommandGroup(after: .pasteboard) {
                Button("Check All Tracks") { for index in model.rows.indices { model.rows[index].include = true } }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(model.phase != .ready)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-job (a rip or a burn) asks first, then lets the job clean up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !SelfTest.requested, ProcessInfo.processInfo.environment["APP_SNAPSHOT"] == nil,
              let job = Jobs.busy.first else { return .terminateNow }
        let prompt = job.stopPrompt
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        alert.addButton(withTitle: prompt.keep)
        alert.addButton(withTitle: prompt.stop)
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            await job.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Ripple saves only settings. APP_STORE (any value) means a test or snapshot run: it uses a separate
/// settings store, so it never reads or writes your real ones.
enum Store {
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    /// A test or snapshot run starts from an empty store every time, so one run never leaks into the next.
    static let defaults: UserDefaults = {
        guard isOverridden, let suite = UserDefaults(suiteName: "com.michael.ripple.test") else { return .standard }
        suite.removePersistentDomain(forName: "com.michael.ripple.test")
        return suite
    }()
}

/// The About window: the BradysBit brand, and the credits the open-source parts ask for.
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        credits.append(NSAttributedString(string: "A BradysBit app\n\n", attributes: bold))
        credits.append(NSAttributedString(string: """
            MP3 encoding by LAME 3.100, used under the GNU LGPL (lame.sourceforge.io), as a separate library you can replace. \
            The licence and source notice are in the app's Resources/Licenses folder. \
            Album details from MusicBrainz. Cover pictures from the Cover Art Archive and the iTunes Search API.
            """, attributes: body))
        credits.append(NSAttributedString(string: "\n\n", attributes: body))
        credits.append(NSAttributedString(string: "www.bradysbit.com/ripple", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: AppLinks.website,
        ]))
        credits.append(NSAttributedString(string: "  \u{00B7}  ", attributes: body))
        credits.append(NSAttributedString(string: "Privacy and terms", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: AppLinks.privacy,
        ]))
        credits.append(NSAttributedString(string: "  \u{00B7}  ", attributes: body))
        credits.append(NSAttributedString(string: "Leave a tip", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: AppLinks.tip,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// Which burner the app uses: the Mac's, or a stand-in for snapshots and tests.
enum Burners {
    static func make() -> any DiscBurner {
        let env = ProcessInfo.processInfo.environment
        if env["APP_FIXTURE_DISC"] == "1" || env["APP_BURN_FIXTURE"] == "1" || Store.isOverridden {
            return FixtureBurner(deviceName: "USB Burner", state: FixtureBurner.blankCD())
        }
        return DiscRecordingBurner()
    }
}
