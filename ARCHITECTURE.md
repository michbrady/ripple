# Ripple architecture

A BradysBit app. One window, no database: Ripple saves only settings (UserDefaults).

## Targets

```text
CLame       LAME 3.100 encoder, C, vendored (LGPL). No decoder.
CDShim      Two ioctls for reading audio CDs (DKIOCCDREADTOC, DKIOCCDREAD), C.
RippleKit   Plain logic, no SwiftUI. Depends on CLame. Tested by RippleKitTests.
Ripple      The app: SwiftUI views, DiskArbitration, the app model. Depends on RippleKit and CDShim.
```

Dependencies point one way: `Ripple` -> `RippleKit` -> `CLame`. RippleKit never imports AppKit or SwiftUI.

## RippleKit

- `DiscTOC`: table of contents, track lengths, MusicBrainz disc ID and `toc` string.
- `AudioDisc` (protocol), `FixtureDisc`: sectors of a disc. Real adapter: `Ripple/Disc/DeviceDisc.swift`.
- `MP3Encoder`: LAME wrapper. `Ripper`: copies included tracks to MP3 files, with cancel and clean-up.
- `FileNamer`: safe names (`/` and `:`, NFC, 255 bytes, duplicates).
- `MusicBrainz`, `MusicBrainzClient`, `AlbumMatch`, `CoverArt`: lookup, rate limit and retry, cover fetch with an iTunes fallback.
- `AlbumDraft`, `TrackRow`: the album as shown. The one place that decides whether a lookup or the user's typing wins.

## Seams

| Seam | Adapters |
| --- | --- |
| `AudioDisc` | `DeviceDisc` (real drive), `FixtureDisc` (tones, for tests and machines with no drive) |
| `AlbumLookup` (app target) | `LiveLookup` (MusicBrainz, Cover Art Archive), `FixtureLookup` (made-up albums) |
| `MusicBrainzClient.Transport`, `CoverArt.Fetch` | the live network, and fakes in tests |

## App target

- `AppModel`: phase (empty, reading, ready, ripping, done, failed), the `AlbumDraft`, the lookup task, the rip task, Output Folder. Views read it through the environment.
- `DiscMonitor`: DiskArbitration. Watches for CD media and refuses the system's mount of audio discs while Ripple runs, so Music does not open.
- `ContentView`: window, album header, cover, track list, bottom bar, match picker.
- `Snapshot`, `SelfTest`: agent modes (`tools/snap.sh`, `tools/selftest.sh`). Both refuse to run unless `APP_STORE` is set, so they never touch real settings.

## Checks

`swift test` (RippleKit), `tools/selftest.sh` (the app's own functions on a fixture disc), `tools/snap.sh` (every page, light and dark), `tools/grid-lint.sh`.
`RIPPLE_LIVE=1 swift test --filter LiveLookup` runs one test against the real MusicBrainz and cover services.
Real-drive checks are manual: see the stories marked `doing` in `docs/STORIES.md`.

## Not decided yet

A shared job type for ripping and burning. See `docs/architecture-review-2026-10-30.md`: wait for M5, when there are two jobs.
