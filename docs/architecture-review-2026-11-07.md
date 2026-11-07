# Architecture review before wiring the DVD feature into the app, 2026-11-07

Survey: 10,100 lines of Swift (7,570 in Sources). `swift test` passes: 132 tests in 21 suites. Most-changed files this month: SelfTest, Models, ContentView, App. The DVD pipeline (`VideoProbe`, `DVDPlan`, `DVDAuthoring`, `DVDMenu`, `DVDBuilder`, `ProcessRunner`, about 1,000 lines) is in RippleKit with tests but no caller in the app target yet. The signal is forward-looking: the next step adds a third long job and a new screen.

## SelfTest.swift is one 1,125-line enum  [Strong]

Files: Sources/Ripple/SelfTest.swift (1,125 lines; 15 check groups, one per milestone)
Signal: file over 1,000 lines (the act line); also the most-changed file this month.
Problem: Every feature appends another group to one `@MainActor enum`. The DVD checks would be the 16th group. Finding one group, or running only the burn checks, means scrolling a 1,100-line file. Nothing is shared between groups except `check`, `wait`, and `finish`.
Proposal: Keep `SelfTest` as the entry point (`runIfRequested`, `check`, `wait`, `finish`, about 60 lines). Move each group to `extension SelfTest` in `Sources/Ripple/SelfTest/<Group>Checks.swift`. Mark the shared helpers `static` without `private`.

```swift
// SelfTest/BurnChecks.swift
extension SelfTest {
    static func burnChecks(burn: BurnModel, out: URL) async { ... }
}
```

Benefits: Locality: a new feature adds a file, not 100 lines to a big one. No file passes 250 lines. The DVD checks land in their own file.
Proof of same behavior: `tools/selftest.sh` prints the same check names and the same pass count before and after (save both outputs and diff them).
Plan: one commit per move would be 15 commits for no gain, so group them: (1) split the helpers into `SelfTest.swift`; (2) move rip checks (attention, tag, format, lookup, loose match, cover prep); (3) move burn checks (burn, real burn, installer, link, library); (4) move CD and drive checks (real CD, real drive, polish, aiffPCM). Each commit builds and the diff of the self-test output is empty.

## Give the DVD build a seam before the app calls it  [Strong]

Files: Sources/RippleKit/DVDBuilder.swift (234 lines), Sources/RippleKit/DiscLayout.swift, Sources/Ripple/Burn/BurnModel.swift (408 lines)
Signal: before a big feature; a dependency that cannot be replaced in the self-test.
Problem: `DVDBuilder` is a concrete struct that runs ffmpeg, dvdauthor, spumux, and mkisofs. RippleKit tests swap in stand-in tools, but the app's self-test and snapshots cannot build a DVD without the real tools. Every other long job has a fixture adapter (`AudioDisc`/`FixtureDisc`, `DiscBurner`/`FixtureBurner`), so the self-test and snapshots never need hardware. DVD would be the only one that does.
Proposal: One protocol, two adapters, same shape as `DiscBurner`.

```swift
public protocol DVDMaker: Sendable {
    func build(_ project: DVDProject,
               progress: @escaping @Sendable (DVDBuildStage, Double) -> Void) async throws -> DVDBuildResult
}
// DVDBuilder conforms (real). FixtureDVDMaker writes a tiny VIDEO_TS folder and an .iso stub, and can fail at a chosen stage.
```

`DVDBuilder.init(tools:project:work:)` stays; `build` takes the project so the model holds one `any DVDMaker`.
Benefits: Snapshots show progress, done, and each `DVDBuildError` with no ffmpeg installed. The self-test covers the whole flow. A failing stage is testable (today only RippleKit's stand-in tools reach that path).
Proof of same behavior: the existing DVDBuilder tests pass unchanged. Add one test that `FixtureDVDMaker` reports every `DVDBuildStage` in order.
Plan: (1) add the protocol and conform `DVDBuilder`; (2) add `FixtureDVDMaker` with a test; (3) then build the DVD part of `BurnModel` against the protocol.

## DVD build is a third StoppableJob, in its own model  [Worth exploring]

Files: Sources/Ripple/Burn/BurnModel.swift (408 lines), Sources/Ripple/StoppableJob.swift
Signal: `BurnModel` would grow past 600 lines; the same call the M5 review made for burning.
Problem: Converting video and authoring a disc (minutes of work, with cancel) has its own state: the video list, titles, menu look, standard, per-stage progress. Putting it into `BurnModel` mixes "pick files and burn" with "make a video disc image first".
Proposal: A `DVDModel` in `Sources/Ripple/DVD/` that produces a disc image and hands the result to the existing burn step. It conforms to `StoppableJob`; the quit prompt needs no change because `Jobs.busy` asks every registered job. Decide this once the first DVD screen is sketched: if the DVD flow turns out to be "BurnModel with one more disc type", keep it there.
Benefits: Locality. The quit and cancel paths stay as they are.
Proof of same behavior: burn self-test checks and the 16 rip and burn snapshot layouts unchanged.
Plan: design note in `docs/DVD-DESIGN.md` first; no code move today.

## ARCHITECTURE.md does not describe the DVD pieces  [Worth exploring, no risk]

Files: ARCHITECTURE.md, Sources/RippleKit/{VideoProbe,DVDPlan,DVDAuthoring,DVDMenu,DVDBuilder,ProcessRunner,MP3Converter}.swift
Signal: the doc and the code disagree (the "Done when" check of this skill).
Problem: The RippleKit list stops at burning. A reader finds seven files with no map: which are pure (`DVDAuthoring` builds argument lists and XML, `DVDMenu` draws), which start processes (`ProcessRunner`, `DVDBuilder`), and where the one seam will be.
Proposal: Add a "DVD" bullet group to RippleKit and a row to Seams in the same commit as the seam above.
Proof of same behavior: none needed (docs only).
Plan: one commit with the seam.

## Small cleanups  [Speculative]

- `ProcessRunner.swift` has a comment about `yt-dlp` that does not belong to this app. Fix the comment when the file is next touched.
- `Models.swift` is 531 lines. `showSnapshot` (about 60 lines) could move into an extension in `Snapshot.swift`, as the last two reviews suggested. Do it when Models.swift is next touched, or at 600 lines.
- `DVDMenu.swift` holds layout, looks, and the renderer (285 lines). Fine today. Split `DVDMenuRenderer` out if it passes 400.

## Top recommendation

Do card 1 (split `SelfTest.swift`) first, because the DVD checks need somewhere to go and the file is past the act line. Then card 2 (the `DVDMaker` seam, with the ARCHITECTURE.md update) before any app code calls the DVD pipeline.

## Considered, not recommended

- **Moving `ProcessRunner` into its own target.** One user, no reason to swap it; RippleKit tests already stand in with scripts.
- **A generic job queue.** Three jobs, one at a time. `StoppableJob` is enough.
- **Splitting `ContentView.swift` (434 lines).** It reads top to bottom, and nothing in the DVD plan touches it.
- **Merging `DVDPlan` and `DVDAuthoring`.** One decides what goes on the disc, the other writes the commands; each is easy to test alone.
