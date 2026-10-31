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
- `MP3Encoder`: LAME wrapper. `TrackWriter` (protocol) with `MP3TrackWriter` (ID3 tag, then audio, then the Xing frame) and `M4ATrackWriter` (Core Audio AAC). `Ripper`: copies included tracks to files in the chosen format, with cancel and clean-up.
- `SectorReader`: retries failed reads, and with Check for Errors reads again until two reads agree, clearing the drive's cache in between. Unreadable sectors become silence and are listed in `ReadIssues`; the ripper saves the track and reports `needsAttention`.
- `TrackTags`, `ID3Tag`, `MP4Tagger`: what goes into each file. `ID3Tag` writes ID3v2.4. `MP4Tagger` rebuilds an .m4a with iTunes-style tag atoms and shifts the chunk offsets.
- `FileNamer`: safe names (`/` and `:`, NFC, 255 bytes, duplicates).
- `MusicBrainz`, `MusicBrainzClient`, `AlbumMatch`, `CoverArt`: lookup, rate limit and retry, cover fetch with an iTunes fallback.
- `BurnScanner`, `BurnItem`, `BurnPlan`, `BurnJob`, `DiscBurner` (protocol), `FixtureBurner`: everything burn mode decides, with no UI and no drive. `BurnPlan` counts blocks (CD audio sectors, 2 KB data blocks) and says whether the files fit.
- `AlbumDraft`, `TrackRow`: the album as shown. The one place that decides whether a lookup or the user's typing wins.

## Seams

| Seam | Adapters |
| --- | --- |
| `AudioDisc` | `DeviceDisc` (real drive), `FixtureDisc` (tones, for tests and machines with no drive; it can fail, recover, or return wrong data to test `SectorReader`) |
| `AlbumLookup` (app target) | `LiveLookup` (MusicBrainz, Cover Art Archive), `FixtureLookup` (made-up albums) |
| `TrackWriter` | `MP3TrackWriter`, `M4ATrackWriter` |
| `DiscBurner` | `DiscRecordingBurner` (the Mac's burner, app target), `FixtureBurner` (records jobs; used by the self-test, snapshots, and test runs) |
| `MusicBrainzClient.Transport`, `CoverArt.Fetch` | the live network, and fakes in tests |

## App target

- `AppModel`: phase (empty, reading, ready, ripping, done, failed), the `AlbumDraft`, the lookup task, the rip task, and the saved settings (Output Folder, format, MP3 quality) in an injected `UserDefaults`.
- `CoverPrep`: makes a cover JPEG or PNG of a sensible size before it is embedded. Views read it through the environment.
- `DiscMonitor`: DiskArbitration. Watches for CD media and refuses the system's mount of audio discs while Ripple runs, so Music does not open.
- `BurnModel` (`Burn/`): burn mode. Source Folder, file list with undo, the disc in the drive (watched), Audio CD or MP3 Disc, and the burn. `BurnView` draws it. `AppModel.mode` switches between rip and burn.
- `StoppableJob`: ripping and burning both conform. The quit prompt asks every busy job (`Jobs.busy`).
- `ContentView`: window, album header, cover, track list, bottom bar, match picker.
- `Snapshot`, `SelfTest`: agent modes (`tools/snap.sh`, `tools/selftest.sh`). Both refuse to run unless `APP_STORE` is set, and then use a settings store that is emptied at launch, so they never touch real settings and never leak into each other.

## Shipping

`./build.sh` builds the app into `~/Applications`. `tools/make-dmg.sh` packs it into `website/Ripple.dmg`, the installer: a window with Ripple, an Applications shortcut, and an arrow (`tools/dmg-background.swift` draws the picture; Finder lays out the window). `website/source/build.py` then rebuilds `website/index.html` with the disk image's size and checksum. The app is signed ad hoc and not notarized; see `website/README.md`.

## Checks

`swift test` (RippleKit), `tools/selftest.sh` (the app's own functions on a fixture disc), `tools/snap.sh` (every page, light and dark), `tools/grid-lint.sh`.
`RIPPLE_LIVE=1 swift test --filter LiveLookup` runs one test against the real MusicBrainz and cover services.
`RIPPLE_REAL_DRIVE=1` adds a read-only check of the real burner's status to the self-test.
Real-disc checks are manual: see the stories marked `doing` in `docs/STORIES.md`.

## Not decided yet

Nothing open. `docs/architecture-review-2026-10-30-m5.md` has the reasoning for separate rip and burn models.
