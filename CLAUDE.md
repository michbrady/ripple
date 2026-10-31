# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Ripple

A native macOS 26 app in SwiftUI (a BradysBit app, bundle id `com.michael.ripple`). One window: it rips an audio CD to MP3 or M4A with a MusicBrainz lookup, and burns MP3 files to an Audio CD or MP3 Disc. It runs on this Mac only. There is no database and no server; only settings are saved (UserDefaults).

Read `ARCHITECTURE.md` for the targets, seams, and what each type does. `docs/BRIEF.md` is the brief, `docs/STORIES.md` the user stories, `docs/FIXLOG.md` the bugs found and the rule each taught, `docs/RELEASING.md` the signing and notarizing steps.

## Layout

- `Sources/RippleKit/` rules and data logic with no SwiftUI or AppKit. Tests in `Tests/RippleKitTests/`.
- `Sources/Ripple/` the app: SwiftUI views, DiskArbitration, `AppModel`, `BurnModel` (`Burn/`), real-drive adapters (`Disc/`). `UI/` holds the theme, grid, and window behaviors.
- `Sources/CDShim/` (two CD ioctls in C) and `Sources/CLame/` (LAME header only). LAME is built from `vendor/lame` into `.lame/` and shipped as a separate dylib inside the app (LGPL).
- `Package.swift` a Swift package. There is no Xcode project.
- `Icon/AppIcon.icon` an Icon Composer file; `tools/make_icon.sh` compiles it, `tools/icon_review.sh` renders every look into one PNG.
- `website/` the download page and privacy page; `website/source/build.py` regenerates `index.html`.

## Architecture rules

- Dependencies point one way: `Ripple` -> `RippleKit` -> `CLame`. Put decisions in RippleKit so they are testable with no UI and no drive.
- Hardware and network sit behind seams (`AudioDisc`, `AlbumLookup`, `TrackWriter`, `DiscBurner`, `MusicBrainzClient.Transport`). Each has a fixture adapter used by tests, the self-test, and snapshots. Add new I/O the same way.
- The `Ripple` target defaults to `@MainActor` isolation (`defaultIsolation`); RippleKit does not.
- Ripping and burning are separate models (`AppModel`, `BurnModel`); both conform to `StoppableJob` so the quit prompt can ask every busy job.

## Build and check

- First time (and after clearing `.lame/`): `tools/build-lame.sh`. `./build.sh` runs it for you, but plain `swift build` and `swift test` need it done first.
- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
- Unit tests: `swift test --scratch-path ~/Library/Developer/Ripple/test-build`. One test: add `--filter RipperTests/testName`.
- `RIPPLE_LIVE=1 swift test --filter LiveLookup` hits the real MusicBrainz and cover services. `RIPPLE_REAL_DRIVE=1` adds a read-only burner check to the self-test.
- Self-test (the app's real functions on a fixture disc and a /tmp store): `tools/selftest.sh`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`. It runs the installed app, so run `./build.sh` first.
- After every UI change, take snapshots with sample data and look at them: `tools/snap.sh`.
  It writes `/tmp/Ripple-shots/<page>-light.png` and `-dark.png` for every sidebar page, and `settings-<tab>-light.png` and `-dark.png` for every Settings tab, then quits. `APP_SNAPSHOT_PAGES=all,settings tools/snap.sh` limits the pages.
  For a panel, sheet, or popover, add a capture to `Snapshot.swift` like the Settings loop.
- Snapshots, seed data, and the self-test refuse to run without `APP_STORE` in /tmp (the scripts set it). Never test against the real settings or anything in `~/Library/Application Support/Ripple/`.
- A test that can eject, move, or delete must not be able to see anything it did not create (see `docs/FIXLOG.md`).
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/Ripple-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors, the grid checks pass, and you looked at the light and dark snapshots.
- Real-disc and real-burner checks are manual; see the stories marked `doing` in `docs/STORIES.md`.

## Release

`tools/release.sh` builds with the hardened runtime, signs, notarizes the app and the DMG, and rebuilds the website. It needs the one-time Developer ID and `notarytool` keychain setup in `docs/RELEASING.md`. Never paste credentials into the chat or the project. Changing the bundle id resets people's saved settings.

## Design rules

- Design rules: `design/DESIGN-SYSTEM.md`. Use its tokens; never raw colors, radii, or durations.
- Use Apple's controls and system styles. Only the accent color is custom: `UI/Theme.swift` (`ThemeStore.defaultID`). People change it, and light or dark mode, in Settings > Appearance.
- Views use `.tint`, `Palette.accent`, `Palette.accentText` (accent-colored text), and `Palette.onAccent` (text on an accent fill). Never hard-code colors, radii, or durations in views.
- Compare accents: add `APP_ACCENT=<id>` to the snapshot command.
- Spacing comes from `Space` in `UI/Grid.swift`, on a 4 pt grid. Mark custom pages and cards with `.gridArea` and `.gridProbe`.
- Windows open calm: `.noInitialFocus()` on every window and sheet (no focus ring or selected text on open), `.fitsContent()` on sheets and Settings tabs (no scroll bar with nothing to scroll). System scroll bars. Both in `UI/WindowBehavior.swift`.
- Settings: one tab per topic in `SettingsView.swift`, one grouped Form per tab. Add a case to `SettingsTab` for a new tab.
- Window chrome (title bar, toolbar, sidebar, menus, sheets) stays system. Buttons use system styles, like `.borderedProminent`.
- Colors: `.primary`, `.secondary`, `.tint`, and system colors. Never fixed grays or white for text.
- Every action has a menu bar item and a keyboard shortcut.
- `Label` for icon and text pairs. SF Symbols for icons.
- `ContentUnavailableView` for empty states.
- Liquid Glass belongs to floating controls only, never to content.

## Skills

The bama plugin has a skill for each step: `mac-design` (design rules),
`design-system` (accent and tokens), `layout-grid`, `ux-design`,
`swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`,
`test-mac-app`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.
