# Ripple

A BradysBit app. The name stays Ripple; BradysBit is the brand that makes it (About window, copyright line).

A one-window Mac app that rips an audio CD to MP3 or M4A files, looks up the album details for you, names every file after its song title, and burns MP3 files back to a CD.

Choices below were decided by the agent from `docs/research/cd-ripper.md`, because the user gave only the idea. Bundle id: `com.michael.ripple`. Change either in one line.

## Replaces
Apple Music's Import CD (no error warning, "Track 01" when lookup fails) and XLD (audiophile setup, dated UI). Decided by the agent.

## Main jobs
1. Insert a disc and see its tracks, album, artist, and cover art, filled in automatically.
2. Pick MP3 or M4A, pick a folder, and rip. Files land as `Artist/Album/01 - Title.ext` with tags and cover art embedded.
3. Fix details when the lookup is wrong or empty: choose another match or edit any field before ripping.
4. Burn: put a blank disc in the drive, choose a folder on the Mac, and burn its MP3 files. Two disc types: Audio Disc (plays in any player) and MP3 Disc (the files copied as they are). Added by the user after the first brief.

## Data
- Disc: table of contents, disc ID, drive, state (reading, ready, ripping, done).
- Track: number, title, artist, length, include flag, status (waiting, ripping, done, needs attention).
- Album: title, album artist, year, disc N of M, compilation flag, cover art, MusicBrainz release id.
- BurnProject: source folder, ordered list of its MP3 files (title, artist, length, size), disc type, used space against the blank's capacity, state (editing, burning, done).
- Settings: format (MP3 by default, or M4A), quality (VBR default, CBR option for MP3), output folder, eject when done.

## Shape
One window with a Rip and Burn switch in the toolbar, no sidebar. Rip: a track list with the album header on top, and a bar for format, folder, and a Rip button. A Settings window for defaults. macOS 26 or later.
Needs the internet only for the album lookup and cover art. Ripping and encoding work offline, with manual entry as the fallback. No accounts.
Non-sandboxed, Developer ID signed and notarized, because raw disc access has no sandbox entitlement.

## System hooks
Disc insert (DiskArbitration claim, so Music does not grab it), blank-disc detection and burning through DiscRecording, eject when done, a Finder reveal of the finished album. No global shortcut, no menu bar item.

## Reference
XLD (settings and ripping modes) and Apple Music's import (the simple flow), by public help pages. XLD is not installed here, so `clone` is skipped.

## Look
Native, with the system accent color, so it reads as a built-in Mac app. Cover art is the visual anchor.

## Not in version one
- AccurateRip, drive offsets, cue sheets, CUETools, and lossless formats (FLAC, ALAC).
- A file-name template editor, batch library tools, and re-tagging existing files.
- Sync, accounts, and multi-drive ripping.
- CD-Text, gapless burn tuning, and burning M4A files.
