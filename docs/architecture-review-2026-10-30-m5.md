# Architecture review before M5 (burning), 2026-10-30

Survey: 4,600 lines with tests. No file is over the limits (`Models.swift` 433, `ContentView.swift` 388, `SelfTest.swift` 366). No fix-log. Most-changed files: SelfTest, Models, ContentView, Ripper (all grew with each milestone, as expected). The signal is forward-looking: M5 adds a second long job.

## Burning gets its own model, not more state on AppModel  [Strong]

Files: Sources/Ripple/Models.swift (433 lines)
Signal: before a big feature; the new feature would push a file past 600 lines.
Problem: Burning needs its own state (Source Folder, file list, drive and blank-disc status, capacity, disc type, progress). Adding it to `AppModel` would put about 250 lines there, mix two unrelated lifecycles (rip a disc, burn a disc), and make the quit prompt and Cancel logic branch on mode.
Proposal: A separate `BurnModel` in `Sources/Ripple/Burn/`, injected in the environment next to `AppModel`. The window switches between two views on a mode saved in settings. Pure logic (capacity math, file ordering, MP3 file reading, audio decoding to PCM, and the disc-layout rules) goes into RippleKit with tests, behind one seam: `DiscBurner` (protocol) with `DiscRecordingBurner` (real) and `FixtureBurner` (records what it was given). This is the same shape as `AudioDisc`.
Benefits: Locality: burn changes touch `Burn/` and one RippleKit file. The fixture burner makes the whole flow testable with no blank disc.
Proof of same behavior: 74 unit tests, 58 self-test checks, and the 16 rip-page layout files stay unchanged while M5 is built.
Plan: build `BurnModel` and the RippleKit pieces first (they compile alone), then the view, then the quit prompt.

## One protocol for jobs that can be stopped  [Worth exploring, do with the burn commit]

Files: Sources/Ripple/App.swift (`applicationShouldTerminate`), Models.swift (`stopRipping`)
Signal: two long jobs now exist (rip, burn), each needing Cancel and a quit prompt.
Problem: The quit prompt asks `AppModel.current` only.
Proposal: A small `StoppableJob` protocol (`isBusy`, a prompt, `stop() async`), with `AppModel` and `BurnModel` registered. `applicationShouldTerminate` asks each.

```swift
@MainActor protocol StoppableJob: AnyObject {
    var isBusy: Bool { get }
    var stopPrompt: (title: String, detail: String) { get }
    func stop() async
}
```

Benefits: One quit path for both jobs; a third job costs no change in the delegate.
Proof of same behavior: the Stop Ripping? prompt behaves as before.
Plan: add with `BurnModel`, in the same commit as its quit prompt. Two real callers by then.

## Snapshot seeding out of AppModel  [Worth exploring]

Files: Sources/Ripple/Models.swift (`showSnapshot`, about 60 lines)
Signal: test hooks in the app type (carried over from the last review).
Proposal: Move to an `extension AppModel` in `Snapshot.swift`.
Benefits: 60 fewer lines in the model. Not urgent now that burning gets its own model.
Proof of same behavior: snapshot layout files unchanged.
Plan: one commit, whenever Models.swift is next touched.

## Top recommendation

Build burning as a separate `BurnModel` with the `DiscBurner` seam (card 1). It is a design rule for M5 more than a refactor, so no existing code moves now.

## Considered, not recommended

- **Merging rip and burn into one "Disc" mode in `AppModel`.** They share an Eject button and a window, nothing else.
- **A generic job queue.** Two jobs, one at a time. A protocol is enough.
- **Splitting `SelfTest.swift` (366 lines).** It reads top to bottom, one function per milestone. Split it when it passes 600.
