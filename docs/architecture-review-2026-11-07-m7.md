# Architecture check-in at the end of M7 (Video DVD), 2026-11-07

Survey: 9,240 lines in Sources, 217 self-test checks, 62 XCTest tests and 134 Swift Testing tests, and one test that builds a real disc image with the real tools. Hot spots this month: `STORIES.md`, `SelfTest.swift`, `ContentView.swift`, `App.swift`, `DVDChecks.swift`, `DVDModel.swift`. The earlier review (same day, before the DVD screen) recommended splitting `SelfTest.swift` and adding the `DVDMaker` seam. Both were done, and both paid off: the DVD checks have their own file, and the whole build, cancel, failure, and burn flow is tested with no ffmpeg and no drive.

## DVDView.swift split into four view files  [Done in this check-in]

Files: `DVD/DVDView.swift` (392 lines, eight views)
Signal: a view file over about 300 lines.
Change: `DVDView` and `DiscTypeHeader` (61 lines), `DVDList` with its empty page and row (163), `DVDBar` (86), and the building and ready pages (91). No code changed, only where it lives.
Proof of same behavior: the self-test still passes all 217 checks, the build is clean, and the snapshot layout files are unchanged.

## DVDModel is 448 lines  [Worth exploring, not done]

Files: `DVD/DVDModel.swift` (448 lines)
Signal: a type over 400 lines.
Problem: One type holds the video list, rename and order with undo, the TV Standard and screen choices, the Menu choices (look, name, picture, music), the build, saving and burning state, and the snapshot seeding. They change for different reasons, and a story usually touches only one.
Why it was not split today: `items`, `phase`, `savedImage` and the menu fields are `private(set)`, so the methods that change them must stay in the same file. A split into extensions would first mean opening those setters, which weakens the guard that only the model changes them.
Proposal, when the next DVD story lands: pull the menu choices (`look`, `discName`, `backgroundURL` and friends, `menuKey`, the file choosers) into a small `DVDMenuChoices` value that `DVDModel` holds. It has no behavior that depends on the list, it is what `DVDMenuInspector` reads, and it makes the preview key testable without the model.
Proof of same behavior: the self-test's menu, picture, and music checks, and the snapshots `burn-videoMenu`, `burn-videoMenuDaylight`, and `burn-videoScenes`.

## Snapshot seeding is in the models  [Speculative, carried from two reviews]

`BurnModel.showSnapshot` (about 80 lines) and `DVDModel.showSnapshot` (about 60) sit in the models. Move both into extensions in `Snapshot.swift` when either model is next touched. `private(set)` has the same cost as above, so this waits for the same change.

## Top recommendation

Nothing is urgent. Do the `DVDMenuChoices` extraction before the next feature that adds menu options (for example moving menus), not before.

## Considered, not recommended

- **A generic stage-runner for `DVDBuilder`.** The five stages read top to bottom in one 250-line function, they share a work folder, and the real-tools test covers them end to end. Splitting would spread that story across files.
- **Putting `DVDMaker` and `DiscBurner` behind one "Job" protocol.** Building and burning have different progress, different cancel rules (burning cannot stop once writing starts), and different failure text.
- **Moving the menu drawing into its own target.** It is pure CoreGraphics, tested, and used only by `DVDBuilder` and the preview.
- **Splitting `DVDChecks.swift` (319 lines).** It reads top to bottom, one function per story. Split it when it passes 600.
