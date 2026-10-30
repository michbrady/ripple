# CD ripper

Research for Ripple. Done 2026-10-30.
[V] verified in a source, [K] from knowledge, [U] unverified, test first.

Question: what makes the best CD ripper on the Mac.
Decision it informs: which features go in version one, and which APIs and libraries to use.
"MP4" in the request is read as M4A (AAC in an MP4 container).

Caveats: the Market and Reviews searches returned snippets, not full pages. sbooth.org/Rip returned 403. No Reddit or Hacker News threads came back, so forums stand in and many are old.

## Findings
- Only XLD (free, v20250302, native Apple Silicon, MP3 via a separate LAME plugin) and Apple Music import (AAC by default) are clearly alive. [V](https://tmkk.undo.jp/xld/index_e.html) [V](https://support.apple.com/guide/music/import-songs-from-cds-mus2935/mac)
- dBpoweramp is paid, lists macOS 26 and 27, checks AccurateRip on every rip, and queries 5 metadata sources. [V](https://www.dbpoweramp.com/cd-ripper.htm) Mac price and Apple Silicon support: [U].
- fre:ac last released in 2023 (v1.1.7). [V](https://www.freac.org/) Whipper is Linux-only. [V](https://github.com/whipper-team/whipper) Max is discontinued. [V-weak](https://alternativeto.net/software/max/?platform=mac) Rip by Stephen Booth has no releases and unknown status. [V](https://github.com/sbooth/Rip)
- Whether any current Mac App Store ripper is worth using: [U]. Phile Audio and ParanoiaImport exist. [V](https://apps.apple.com/us/app/phile-audio/id413934579?mt=12)
- The gap is ease of use, not ripping accuracy. Accurate rippers target audiophiles. The free zero-setup option, Apple Music, leaves "Track 01" when lookup fails and gives no warning on bad rips. [V][K]
- Disc access: DiskArbitration to see, claim and unmount the disc. `/dev/rdiskN` with `DKIOCCDREADTOC` and `DKIOCCDREAD` (2352 bytes per CDDA sector) for the table of contents and audio. [V](https://opensource.apple.com/source/IOCDStorageFamily/IOCDStorageFamily-32/IOCDMediaBSDClient.h.auto.html) A 2006 report says repeat reads can return cached data. [V](https://lists.apple.com/archives/darwin-dev/2006/Jan/msg00085.html) Current behavior: [U].
- The CDDA filesystem mounts tracks as `.aiff` files. Easy to read, but no error detection. [K]
- No documented sandbox entitlement for raw optical access. [V, absence] Ship non-sandboxed, Developer ID signed and notarized. [K]
- AAC/M4A: AVAssetWriter or AVAudioConverter. AAC needs priming info. [K] [V](https://medium.com/fandom-engineering/priming-cmsamplebuffer-containing-aac-encoded-data-using-apples-core-media-api-c5b2bf0e62a1)
- MP3: Apple ships no encoder. Link LAME (`libmp3lame`) dynamically under LGPL, credit it, leave the GPL decoder out. [V](https://lame.sourceforge.io/license.txt) MP3 patents expired in 2017. [V, secondary]
- MusicBrainz: `/ws/2/discid/<id>?toc=...` does a fuzzy match when the ID is unknown. About 1 request per second, a real User-Agent required. [V](https://musicbrainz.org/doc/MusicBrainz_API) [V](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)
- Disc ID: SHA-1 of the TOC hex string, base64 with `+/=` swapped for `._-`. About 40 lines of Swift. [V](https://musicbrainz.org/doc/Disc_ID_Calculation)
- Cover Art Archive: `/release/{mbid}/front-500` redirects to archive.org, 404 when no cover. [V](https://musicbrainz.org/doc/Cover_Art_Archive/API)
- Tagging: AVFoundation cannot write ID3. TagLib covers ID3v2 and MP4 atoms (`©nam`, `covr`). [K] AVAssetWriter may silently drop unknown metadata. [V, forum]
- Filenames: replace `/`, strip control characters, trim a leading `.` and trailing spaces, normalize to NFC, cap at 255 UTF-8 bytes. [K]
- Music app opens on disc insert and can fight for the drive. Claim the disc with `DADiskClaim`. [K][U]
- This Mac has no optical drive. LAME, ffmpeg and XLD are not installed. Hardware tests need a USB drive.

## Likes and dislikes
| App | People like | People dislike | Sources |
| --- | --- | --- | --- |
| XLD | Secure ripping with AccurateRip; clear batch settings; many formats; free and updated | Slower than Apple Music; occasional crashes; Gatekeeper block on first run; dated UI [K] | [MacRumors](https://forums.macrumors.com/threads/xld-vs-music-app-cd-ripping.2415123), [Macworld](https://www.macworld.com/article/668800/best-alternatives-to-itunes-for-ripping-cds-to-mp3.html) |
| Apple Music | Fast; preinstalled and simple [K] | No error verification, bad rips surface on playback; drive trouble on some Macs; metadata depends on Gracenote [K] | [MacRumors](https://forums.macrumors.com/threads/cd-ripper.2408913) |
| dBpoweramp | Best metadata and tag editor; AccurateRip lets a cheap drive work | Mac version lags XLD; lookup stalls at manual search; drive not detected on v16; paid | [dBpoweramp forum](https://forum.dbpoweramp.com/forum/dbpoweramp/cd-ripper/35646-problems-with-cd-ripper-16-mac) |
| fre:ac | Free alternative to Apple Music; ripping works | Dated, cluttered UI; Mac CD crashes (fixed in 2015); low maintenance | [fre:ac](https://freac.org/latest-news-mainmenu-2/14-freac/206-freac-development-status-update-062015) |
| Phile Audio | Simple and fast; several drives at once; MP3, AAC, FLAC, ALAC | Crash on install; output went to the wrong folder; no automatic album art; freedb lookups may fail | [App Store](https://apps.apple.com/us/app/phile-audio/id413934579?mt=12) |

Patterns: must have are verified ripping, working metadata with album art, and a stable app. Chances to do better are crashes, wrong output folders, dated UI, silent bad rips, stalled lookups, and weak multi-disc and compilation defaults.

## Feature matrix
| Feature | XLD | dBpoweramp | Apple Music | Version one? |
| --- | --- | --- | --- | --- |
| MP3 (VBR default, CBR option) | Plugin [V] | Yes [V] | Yes [V] | Yes |
| M4A (AAC) | Yes [V] | Yes [V] | Default [V] | Yes |
| Auto metadata | 5 sources [V] | 5 sources [V] | Gracenote [K] | Yes (MusicBrainz first) |
| Fallback source and manual edit | Yes [V] | Yes [V] | Weak [V] | Yes |
| Cover art embedded | Yes [V] | Yes [V] | [K] | Yes |
| Song-title filenames | Placeholders [V] | Bracket tokens [V] | Track numbers [K] | Yes, good defaults, no template editing |
| Multi-disc and compilation handling | [U] | Conditional tokens [V] | [K] | Yes, automatic |
| Eject when done | [U] | Yes [V] | [K] | Yes |
| Error re-read and "may have errors" warning | Yes [V] | Yes [V] | Off by default [V] | Yes |
| Auto-start on disc insert | Yes [V] | [U] | Prompt [K] | Nice |
| AccurateRip verification | Yes [V] | Yes [V] | No [K] | Later |
| Drive offsets, cue sheets, CUETools, C2, HTOA, FLAC and ALAC | Yes [V] | Yes [V] | No | No (audiophile extras) |

## Decisions
1. Version one writes MP3 and M4A only, because the request names them and every competitor offers both. Planned test: write both formats and play them in Music and QuickTime.
2. Non-sandboxed Developer ID app with DiskArbitration and `/dev/rdiskN` ioctls, because no sandbox entitlement is documented for raw disc access. Planned test: with a USB drive on macOS 26, open `/dev/rdisk`, read the TOC and a track, and note any permission prompt.
3. Read raw sectors instead of the `.aiff` files, because the filesystem gives no error detection. Planned test: confirm repeat reads are not cached, and compare to the `.aiff` copy.
4. AAC through AVFoundation. MP3 through dynamically linked LGPL LAME vendored as a SwiftPM C target, credited in the About window. Planned test: build for arm64, sign, notarize, encode a track, check the tags and gapless playback.
5. MusicBrainz lookup by TOC at about 1 request per second with a proper User-Agent, picker for multiple matches, Cover Art Archive for art, and a manual edit screen as the no-match fallback, because Apple Music leaves "Track 01" on failure [V]. Planned test: three real discs including a multi-disc set and a compilation.
6. TagLib for ID3v2 and MP4 tags. Planned test: cover art and disc N of M show in Music.
7. Filenames `Artist/Album/01 - Title.ext`, with `Disc N` folders for multi-disc sets and "Various Artists" for compilations, because users write custom tokens to fix this in dBpoweramp [V]. Planned test: titles with `/`, `:`, accents and 255-byte limits.
8. Error-aware ripping: re-read bad frames and flag problem tracks, because Apple Music accepts bad reads silently [V]. Full AccurateRip waits for a later version. Planned test: rip a scratched disc and check the warning appears.
9. Claim the disc with DiskArbitration and eject when done, because Music opens on insert [K]. Planned test: insert a disc with Music running.

## Burning (added 2026-10-30, user request)
Not covered by the four research tracks. Everything here is [K] or [U]; test before trusting.
- Burn an audio CD from MP3s: decode each MP3 to 44.1 kHz 16-bit stereo PCM (AVAudioFile), then write Red Book audio with the DiscRecording framework (`DRBurn`, `DRTrack` with a track producer). [K]
- DiscRecording also gives blank-disc detection and a burner list (`DRDevice`). Needs an external USB burner on current Macs. [K][U]
- An audio CD holds 80 minutes (some blanks 74 or 90). Warn when the list is longer than the blank in the drive. [K]
- CD-Text for titles is optional and rarely read. Skip in version one. [K]
- An MP3 data disc (files stored as-is) is simpler to burn and holds hours of music, but only some players read it. Later. [K]
- User clarification: the user picks a folder on the Mac and Ripple burns the MP3s in it. "Copy/burn" may mean the files as-is, so Ripple offers both disc types.
- Decision 10: offer Audio Disc (default, plays in every player) and MP3 Disc (files copied unchanged, ISO 9660/Joliet data disc, holds hours). Planned test: burn a 3-track Audio Disc and play it in a car or home player, and burn an MP3 Disc and play it from a Mac and an MP3-capable player.
- Open: does DiscRecording burn on macOS 26 with a non-sandboxed app, and does it need a permission prompt? [U]

## Open questions
- Do USB optical drives work through `/dev/rdisk` on macOS 26? Test with a real drive. [U]
- Does `DKIOCCDREAD` still return cached data on repeat reads? Test by reading one sector twice. [U]
- Does the MusicBrainz discid endpoint accept the full `inc` list? Test with one request. [U]
- Does AVAssetWriter write artwork into M4A, or is TagLib needed for both? Test. [U]
- Mac price and Apple Silicon support for dBpoweramp. [U]
- Is any current Mac App Store ripper worth treating as a competitor? [U]
