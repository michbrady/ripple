import AppKit
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

    var body: some Scene {
        Window("Ripple", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 760, height: 560)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Rip Checked Tracks") { model.rip() }
                    .keyboardShortcut("r")
                    .disabled(model.phase != .ready || model.checkedCount == 0)
                Button("Eject Disc") { model.eject() }
                    .keyboardShortcut("e")
                    .disabled(!model.hasDisc)
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

    /// Quitting mid-rip asks first, then lets the rip delete its half-written file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.current, model.isRipping, !SelfTest.requested,
              ProcessInfo.processInfo.environment["APP_SNAPSHOT"] == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop Ripping?"
        alert.informativeText = "Finished tracks are kept. The track in progress is deleted."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Keep Ripping")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await model.stopRipping()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Ripple saves only settings. APP_STORE (any value) means a test or snapshot run: it never reads or writes them.
enum Store {
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }
}
