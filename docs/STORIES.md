# Ripple stories

No reference app, so `Screens:` names the snapshot pages that will show each story:
01-empty, 02-disc-tracks, 03-ripping, 04-done, 05-settings, 06-match-picker, 07-edit-album, 08-needs-attention.
Hardware checks use a USB optical drive. `[self]` steps run against a fixture disc image (a saved table of contents plus sample PCM) when no drive is attached.

## M1 Core loop
Insert a disc, rip it to M4A, find named files on disk.

### S-001 See that no disc is inserted
As the user, I open Ripple with no disc and see what to do.
Screens: 01-empty
Acceptance:
- [snap] The window shows an empty state that says to insert a CD, and mentions a USB drive.
- [self] With no drive attached, the empty state also appears.
UX:
- Flow: launch or eject -> empty state -> insert a disc -> window shows tracks (S-002). Way back: none needed, nothing is open.
- Surface: inline empty state filling the window (empty-state row in the states list, no modal)
- States: empty only. Title "Insert a Disc", body "Ripple reads audio discs from a built-in or USB drive." No button, because the first action is physical.
- Words: "Insert a Disc"; sentence case body; no error tone
- Access: VoiceOver reads title then body; no focusable controls
Status: done

### S-002 Detect an inserted disc
As the user, I insert a CD and Ripple shows it within a few seconds.
Screens: 02-disc-tracks
Depends: S-001
Acceptance:
- [self] A disc-appeared event from DiskArbitration claims the disc, so Music does not open.
- [manual] Insert a real disc with Music running. Ripple shows the disc and Music stays closed.
- [self] Ejecting the disc returns the window to the empty state.
UX:
- Flow: insert disc -> "Reading Disc…" -> track list appears -> Eject from toolbar or File menu (Command-E) returns to the empty state. Way back: Eject.
- Surface: inline in the main window (changes what the window shows; no modal)
- States: loading "Reading Disc…" with an indeterminate bar when the read takes over half a second; error "Ripple cannot read this disc." with "Try Again" and "Eject"; empty returns on eject
- Words: "Reading Disc…", "Eject", "Try Again"; tooltip on the Eject icon "Eject the disc (⌘E)"
- Access: Eject has a label and Command-E; focus moves to the track list when it appears
Status: done
Note: Checked on a real disc (2026-10-30): the app saw the inserted CD and showed its tracks by itself. The mount refusal (so Music stays closed) and eject are still unchecked: Music was running and the disc was already mounted.

### S-003 Read the table of contents
As the user, I see every track with its length, named "Track 01", "Track 02".
Screens: 02-disc-tracks
Depends: S-002
Acceptance:
- [unit] A saved table of contents parses to the right track count, offsets, and lengths.
- [unit] The MusicBrainz disc ID computed from a known table of contents matches its published ID.
- [snap] The track list shows number, title, and length for every track.
- [manual] On a real disc, track count and lengths match the Music app.
UX:
- Flow: disc read -> album header ("Unknown Album" until lookup) above a track list -> user edits (S-013) or rips (S-005). Way back: edits undo with Command-Z.
- Surface: inline main window, a table of tracks (lists a thing people work on; no modal)
- States: loaded list; too much: long titles truncate with the full title in a tooltip, and 99 tracks still scroll smoothly; before lookup the rows read "Track 01"
- Words: column headers "#", "Title", "Artist", "Length"; header placeholder "Unknown Album" and "Unknown Artist"
- Access: arrow keys move between rows; VoiceOver reads "Track 3, Title, 3 minutes 41 seconds, included"
Status: done
Note: Checked on a real disc: a 32-track CD-Extra (a data session after the audio). Track starts and lead-out equal drutil's exactly, and the MusicBrainz layout rule for a data session was applied (lead-out 268,720). MusicBrainz has no exact record for it, so the lookup was a loose search; see the fix log.

### S-004 Read raw audio from a track
As the user, I rip a track and the audio is the same as the disc.
Depends: S-003
Acceptance:
- [self] Reading one track from the fixture yields the exact byte count (sectors times 2352).
- [manual] On a real disc, a ripped track plays with no clicks and its length matches the disc.
- [self] Reading the same sector twice returns fresh data, not cached data.
Status: done
Note: Checked on a real disc: raw reads return exactly sectors x 2352 bytes and match the system's own copy of the audio byte for byte (300 sectors, 7 positioned reads, 40 scattered reads, 6 cold starts). A real 105 s track ripped to a 105.23 s MP3, equal to the disc's length. One earlier run showed 18 differing sectors at the start of a read; it could not be reproduced and is recorded as unexplained. Two reads that agree do not prove the data is right if the drive repeats the same wrong bytes; AccurateRip is in Later.

### S-005 Rip a disc to MP3
As the user, I press Rip and every checked track becomes an MP3 file.
Screens: 03-ripping, 04-done
Depends: S-004
Acceptance:
- [unit] The LAME encoder turns a PCM fixture into an `.mp3` with the right duration.
- [self] The built app runs with LAME bundled as a dynamic library, signed, and the About window credits LAME and its LGPL license.
- [snap] The ripping page shows a progress bar per track and a total.
- [snap] The done page lists the album folder and a Show in Finder button.
- [manual] The files play in Music and QuickTime.
UX:
- Flow: Rip button or Command-R -> rows show per-track progress -> done page with "Show in Finder" and "Rip Another Disc" (which ejects). Way back: Cancel (S-009).
- Surface: inline, the track list turns into progress rows; the done state replaces it (no sheet, because the user watches the result)
- States: loading "Ripping 3 of 12 · Title" with a bar per track and a total; done "Ripped 12 Tracks" with the album folder path; error uses S-024
- Words: "Rip" (toolbar button, tooltip "Rip the checked tracks to the Output Folder (⌘R)"), "Show in Finder", "Rip Another Disc", "Cancel"
- Access: Rip is the default button; progress is announced by VoiceOver at each track and at the end; done is announced in words, not only a checkmark
Status: done
Note: [unit] and [self] pass; LAME is compiled into the app (static), not bundled as a dynamic library. Still to do: [manual] play the files in Music and QuickTime, and show the LAME credit in an About window.

### S-006 Name files by song title
As the user, I get `Artist/Album/01 - Title.m4a`.
Screens: 04-done
Depends: S-005
Acceptance:
- [unit] `/` and `:` in titles become `-`, control characters go, leading dots and trailing spaces trim, and the name is NFC.
- [unit] A name over 255 UTF-8 bytes shortens without splitting a character.
- [unit] Two tracks with the same title get distinct names.
Status: done

### S-007 Choose the output folder
As the user, I pick where files go, and Ripple remembers it.
Screens: 02-disc-tracks, 05-settings
Depends: S-005
Acceptance:
- [self] The chosen folder survives a restart.
- [snap] The bar shows the folder name, with a Change button.
- [self] Files land in the chosen folder, not a default one.
UX:
- Flow: bar shows "Output Folder: Music" -> Change… opens the system folder chooser -> choice saved -> bar updates. Way back: Escape cancels the chooser. Same setting lives in Settings (Command-,).
- Surface: inline button in the bar, opening the system open panel (changes one value, so no custom modal)
- States: default Music folder on first launch; error "Ripple cannot save to this folder. Choose another." when it is unwritable (S-024)
- Words: "Output Folder", "Change…" (ellipsis, it asks for more input), tooltip "Choose where ripped albums are saved"
- Access: Change… reachable by keyboard; VoiceOver "Output Folder, Music, Change button"
Status: done
Note: The restart check now runs: a second AppModel on the same settings store reads back the folder. Try the folder chooser by hand once.

### S-008 Skip tracks
As the user, I uncheck tracks I do not want.
Screens: 02-disc-tracks
Depends: S-005
Acceptance:
- [snap] Each row has a checkbox, and the Rip button shows the checked count.
- [self] Unchecked tracks produce no files.
- [self] With nothing checked, Rip is disabled.
UX:
- Flow: click a checkbox or press Space on a row -> count on the Rip button updates; Command-A in the list checks all. Way back: click again, or Command-Z.
- Surface: inline checkbox in each row (changes one value on screen)
- States: all checked by default; none checked disables Rip and a line under the list says "Check at least one track."
- Words: button "Rip 12 Tracks", "Rip 1 Track"; checkbox label is the track title
- Access: Space toggles the focused row; VoiceOver reads "included" or "not included"; the state is a checkbox, not color alone
Status: done

### S-009 Cancel a rip
As the user, I press Cancel and stop without leaving half files.
Screens: 03-ripping
Depends: S-005
Acceptance:
- [self] Cancel mid-track deletes that partial file and keeps finished tracks.
- [snap] After cancel, the window returns to the track list.
UX:
- Flow: Cancel button or Escape while ripping -> current partial file removed -> window returns to the track list with finished tracks marked done. Way back: press Rip again to resume with the remaining tracks.
- Surface: inline button in the bar, no confirmation (nothing is lost that a second Rip cannot redo; confirm only closing the window mid-rip)
- States: "Cancelling…" until the partial file is gone, then back to the list
- Words: "Cancel", tooltip "Stop ripping. Finished tracks are kept (Esc)"; closing the window mid-rip asks "Stop Ripping?" with "Stop" and "Keep Ripping"
- Access: Escape cancels; focus returns to the Rip button
Status: done

## M2 Metadata
The album fills itself in, and the user can fix it.

### S-010 Look up the album by disc
As the user, I see the album, artist, year, and track titles a few seconds after insert.
Screens: 02-disc-tracks
Depends: S-003
Acceptance:
- [unit] The lookup request carries the table of contents, a real User-Agent, and `inc=artist-credits+recordings+release-groups`.
- [unit] A saved MusicBrainz response maps to album, artist, year, and titles.
- [self] Lookups never exceed one request per second, and a 503 retries after a pause.
- [snap] Titles replace "Track 01" and the album header shows album, artist, and year.
Status: done
Note: Checked live for the MusicBrainz example disc (LiveLookup test, off by default: RIPPLE_LIVE=1). Set LiveLookup.contact to an email or web page before sharing the app: MusicBrainz asks for one in the User-Agent.

### S-011 Choose between several matches
As the user, I pick the right release when a disc matches more than one.
Screens: 06-match-picker
Depends: S-010
Acceptance:
- [unit] Matches rank by exact disc-ID match, then format, then country.
- [snap] The picker lists each release with artist, album, year, country, and track count.
- [self] Choosing a release updates the header and every title.
Status: done
Note: The picker is a sheet, Choose Album. Snapshot: picker-light.png, picker-dark.png.

### S-012 Show cover art
As the user, I see the album cover next to the tracks.
Screens: 02-disc-tracks
Depends: S-010
Acceptance:
- [self] The cover loads from the Cover Art Archive front image.
- [self] A 404 leaves a neutral placeholder and no error banner.
- [snap] The album header shows the cover at a fixed size.
Status: done
Note: Falls back to the iTunes Search API when the Cover Art Archive has no front cover; the fallback only accepts a result whose album name matches. Both checked live for the example disc (the archive answered).

### S-013 Edit album and track details
As the user, I fix any field before ripping, or fill them in when nothing matched.
Screens: 07-edit-album
Depends: S-010
Acceptance:
- [snap] Album title, album artist, year, and each track title and artist are editable in place.
- [self] Edited values flow into the file names and tags.
- [self] With no network, the window still opens with "Track NN" titles and everything editable.
- [self] An edit survives choosing a different match only if the user edited that field.
Status: done

### S-014 Replace the cover art
As the user, I drop my own image on the cover to use it.
Screens: 07-edit-album
Depends: S-012
Acceptance:
- [self] Dropping a JPEG or PNG replaces the cover and the embedded art.
- [snap] A drop target outline shows while dragging.
Status: done
Note: Drag and drop is tested through the model (setCover), not with a real drag; try dropping an image on the Cover by hand.

### S-015 Handle multi-disc sets and compilations
As the user, I get disc folders and "Various Artists" without setting anything.
Screens: 07-edit-album
Depends: S-010
Acceptance:
- [unit] A release with 2 discs puts files in `Disc 1` and `Disc 2` folders and sets disc N of M.
- [unit] A compilation uses album artist "Various Artists" and puts the track artist in the file name.
- [unit] A single-disc album gets no disc folder.
- [manual] Try a real two-disc set and a real compilation.
Status: done
Note: Checked with fixture sets and compilations. The manual check on a real two-disc set and a real compilation is still open.

## M3 MP3 and tags
Both formats, tagged the same way.

### S-016 Pick the format
As the user, I choose MP3 or M4A in the bar.
Screens: 02-disc-tracks, 05-settings
Depends: S-005
Acceptance:
- [snap] A format control shows MP3 and M4A, with the current choice.
- [self] The choice survives a restart.
- [self] A fresh install defaults to MP3, because MP3 is what the user asked to rip to.
- [self] The file extension matches the chosen format.
Status: done

### S-017 Rip to M4A
As the user, I choose M4A and get AAC files that play in Music and on iPhone.
Screens: 03-ripping
Depends: S-016
Acceptance:
- [unit] The encoder turns a PCM fixture into an `.m4a` that AVAudioFile opens with the right duration.
- [manual] The M4A files play in Music and QuickTime.
Status: done
Note: M4A is AAC at 256 kbps written through Core Audio; the file decodes to the right length. Still to do: play one in Music and on an iPhone.

### S-018 Choose MP3 quality
As the user, I pick VBR (default) or a fixed bitrate for MP3.
Screens: 05-settings
Depends: S-005
Acceptance:
- [snap] Settings shows VBR with a quality level, and CBR with 128, 192, 256, and 320 kbps.
- [unit] A CBR 192 encode of a fixture reports 192 kbps.
Status: done
Note: Settings shows four variable levels and four fixed rates. M4A has no quality setting yet.

### S-019 Write tags
As the user, my files carry title, artist, album, year, track and disc number, and cover art.
Screens: 04-done
Depends: S-010, S-005
Acceptance:
- [unit] Reading back an MP3 gives the same ID3v2 fields and cover that were written.
- [unit] Reading back an M4A gives the same MP4 tags and cover.
- [manual] Music shows the cover, title, track number, and disc N of M.
- [unit] A compilation sets the compilation flag.
Status: done
Note: Tags are read back with AVFoundation in unit tests and in the self-test, and both container formats pass afinfo. Still to do by hand: open one MP3 and one M4A in Music and check the cover, title, track number, and disc N of M show.

## M4 Trustworthy rips
Say when a rip may be bad, instead of staying silent.

### S-020 Re-read bad sections
As the user, a scratched disc gets a second look instead of a bad file.
Screens: 03-ripping
Depends: S-004
Acceptance:
- [unit] A read error on a sector retries up to a set number of times.
- [self] A fixture that fails twice then succeeds gives a clean track.
- [self] Reading a sector range twice and comparing catches a mismatch.
Status: done
Note: Also checked on a real disc for speed: Check for Errors costs about 2x with 300-sector reads (4.1x real time against 9.5x). Not tried on a scratched disc.

### S-021 Flag tracks that may have errors
As the user, I see which tracks need attention and can retry them.
Screens: 08-needs-attention
Depends: S-020
Acceptance:
- [self] A track whose retries ran out is marked needs attention and still saved.
- [snap] The row shows a warning icon, and the done page lists those tracks.
- [self] A Retry button on that row re-rips just that track.
Status: done
Note: Snapshot: attention-light.png, attention-dark.png (the story called it 08-needs-attention). A cancelled Retry leaves the old file untouched.

## M5 Burn
Turn MP3 files into an audio CD. Snapshot pages: 09-burn-empty, 10-burn-list, 11-burning, 12-burn-done.
Hardware checks use a USB burner and a blank CD-R. `[self]` steps use a fixture burn target that records the audio instead of writing a disc.

### S-026 Switch to Burn mode
As the user, I switch the window from Rip to Burn.
Screens: 09-burn-empty
Acceptance:
- [snap] A toolbar switch shows Rip and Burn, and Burn shows an empty list that says to drop MP3 files here.
- [self] The mode survives a restart.
Status: done

### S-027 Choose a folder of MP3 files to burn
As the user, I choose a folder on my Mac, and Ripple lists the MP3 files in it. Dropping a folder or files on the window works too.
Screens: 10-burn-list
Depends: S-026
Acceptance:
- [self] Choosing a folder with three MP3s adds three rows with title, artist, and length read from their tags, in track-number order then file name order.
- [self] MP3s in subfolders are included, and the chosen folder is remembered for next time.
- [snap] The empty Burn page shows a "Choose Folder…" button.
- [self] A file with no tags uses its file name as the title.
- [self] A non-MP3 file is skipped, and a message names how many were skipped.
- [snap] Rows show number, title, artist, and length.
Status: done
Note: Folder and drop are tested with real MP3 files made by the ripper. Try the Choose Folder panel and a real drag by hand.

### S-028 Order and remove tracks
As the user, I drag rows to reorder them and remove rows I do not want.
Screens: 10-burn-list
Depends: S-027
Acceptance:
- [self] Dragging a row changes the burn order, and the numbers update.
- [self] Delete removes the selected rows, and Command-Z brings them back.
Status: done
Note: Dragging rows is tested through the model (move), not with a real drag. Try it by hand.

### S-029 See how much fits on the disc
As the user, I see total time against the blank in the drive, before I burn.
Screens: 10-burn-list
Depends: S-027
Acceptance:
- [unit] Total length sums track lengths, and 80 minutes is the default limit.
- [self] With a blank in the drive, the limit uses the blank's real capacity.
- [snap] A bar shows used time and turns to a warning when over the limit, with the Burn button disabled and a message that says how many minutes to remove.
Status: done

### S-030 Detect the burner and a blank disc
As the user, I see whether a burner and a blank disc are ready.
Screens: 10-burn-list
Depends: S-026
Acceptance:
- [self] With no burner, the Burn button is disabled and a line says to connect a USB burner.
- [self] With a burner and no disc, the line says to insert a blank CD-R.
- [self] With a non-blank disc, the line says it is not blank and offers erase only for rewritable discs.
- [manual] Check each state with a real burner.
Status: done
Note: The real burner's status was read on the connected drive (Lenovo USB burner, blank DVD-R, 2,297,888 blocks). Erase for a rewritable disc is not offered: it destroys data, so the message says to erase it in Disk Utility. Check each state with a real disc.

### S-031 Burn an audio CD
As the user, I press Burn and get a CD that plays in any player.
Screens: 11-burning, 12-burn-done
Depends: S-028, S-029, S-030
Acceptance:
- [unit] An MP3 fixture decodes to 44.1 kHz, 16-bit, stereo PCM with the right length.
- [self] The fixture burn target receives every track in list order with no gaps beyond the standard two seconds.
- [snap] The burning page shows the stage (preparing, burning, finishing) and a progress bar.
- [snap] The done page says the disc is ready and ejects it.
- [manual] The disc plays all tracks in order in a CD player.
Status: doing
Note: Renamed from "Audio Disc" to "Audio CD". Checked without a disc: DiscRecording builds a standard CD-audio track from an MP3 (2,352-byte audio blocks, audio data form, the standard 2-second gap, 600 blocks for 8 s), and also converts a 48 kHz mono WAV and a 22 kHz mono AAC to the same format, so MP3s of any rate or channel count work. The disc is closed after burning. A CD-RW gets a heads-up that many older players cannot read it. Not yet done: burn a real Audio CD on a blank CD-R and play it in an old CD player. The real write path works for an MP3 Disc (see S-033). Set RIPPLE_BURN_DEBUG=1 to log the framework's real states on the next burn.

### S-032 Cancel a burn and handle burn errors
As the user, I can cancel before the burn starts, and I get a clear message if it fails.
Screens: 11-burning
Depends: S-031
Acceptance:
- [self] Cancel during preparing leaves the disc untouched.
- [snap] Once writing starts, Cancel is replaced by a note that stopping now ruins the disc.
- [self] A failed burn names the cause (drive error, disc rejected) and offers Try again.
Status: done
Note: Cancel before writing, no Cancel after, and a failed burn are checked with the stand-in. The real burner's abort path is not exercised.

### S-033 Burn the MP3 files as they are
As the user, I choose "MP3 Disc" to copy the MP3 files onto the disc unchanged, so more music fits.
Screens: 10-burn-list
Depends: S-031
Acceptance:
- [snap] A control next to Burn offers "Audio CD" (plays in any player, about 80 minutes) and "MP3 Disc" (holds many hours, needs a player that reads MP3 files), with one line under each.
- [unit] For an MP3 Disc the capacity bar counts file sizes against the blank's megabytes, not minutes.
- [self] The fixture burn target receives the original MP3 files byte for byte, with the folder layout kept.
- [manual] The disc mounts on a Mac and the MP3 files play from it.
Status: doing
Note: FIRST REAL BURN, 2026-10-30, on the blank DVD-R (now used up): three MP3 files burned as an MP3 Disc through DiscRecordingBurner with verification on. The disc mounts on the Mac, holds all three files, and each is byte-for-byte identical to its source (SHA-256), and decodes as MP3. Raw sectors show a hybrid disc: ISO 9660, Joliet (long names), UDF, and HFS+. The file names came out doubled (01 - 01 - One.mp3); fixed afterwards in BurnNaming and covered by unit tests, but not burned again. Still to do: burn again to confirm the names, and play the disc in a standalone MP3 player. For repeat tests use a rewritable disc (DVD-RW or CD-RW); a blank DVD-R or CD-R is used up by one test.

## M6 Polish
Settings, eject, auto-start, icon.

### S-022 Eject when done
As the user, the disc ejects after the last track.
Screens: 05-settings
Depends: S-005
Acceptance:
- [self] With eject on, the disc ejects after a clean rip, and with errors it stays in.
- [snap] Settings has an "Eject when done" toggle, on by default.
Status: done
Note: The finished page stays up after the disc goes out, and Retry then waits for the disc to come back. Real ejecting (DiskArbitration) is untested: this Mac had no music CD.

### S-023 Start on disc insert
As the user, I choose whether inserting a disc starts the rip.
Screens: 05-settings
Depends: S-010
Acceptance:
- [self] With auto-start on, a disc that matches exactly starts ripping after lookup.
- [self] With no match or several matches, it waits for the user.
- [snap] Settings shows the toggle, off by default.
Status: done
Note: Starts only for exactly one exact match, after the cover has had its chance to load.

### S-024 Show clear messages for problems
As the user, I know what went wrong and what to do.
Screens: 08-needs-attention
Depends: S-005
Acceptance:
- [self] A full disk or unwritable folder stops the rip with a message naming the folder.
- [self] An unreadable disc shows "Ripple cannot read this disc" with a Try again button.
- [snap] Each message page uses plain words and one action.
Status: done
Note: An unreadable disc is simulated by replacing how the app opens a disc; a real unwritable folder is used for the folder message; the full-disk wording is checked on the error mapping, not on a full disk. Snapshots: unreadable-light.png, folderProblem-light.png.

### S-025 Add an app icon
As the user, I see a real icon in the Dock and window.
Depends: S-005
Acceptance:
- [snap] The snapshot shows the icon in light and dark looks.
Status: done
Note: Rendered in every look with tools/icon_review.sh (/tmp/Ripple-icon.png). Look at the Dock by hand.

### S-034 Offer to trash the installer
As the user, after I drag Ripple to Applications and open it, I am asked whether to move the installer to the Trash.
Screens: (a system alert, not a snapshot page)
Depends: S-005
Acceptance:
- [unit] The open disk images are read from `hdiutil info -plist`; only an image with a file behind it whose volume holds this app is offered; a file opened twice has every volume found.
- [self] Running from outside Applications or ~/Applications offers nothing.
- [self] With the installer open, the user is asked once; Keep leaves the disk image open and the file in place, and the same file is not asked about again.
- [self] Move to Trash ejects every copy of the disk image and moves the .dmg to the Trash. With no installer open, nothing is offered.
UX:
- Flow: first launch from Applications -> 1.5 s later an alert -> Move to Trash ejects the disk image and trashes the .dmg, or Keep does nothing and is remembered for that file.
- Surface: alert (a problem-free question that needs an answer now; no other row fits).
- Words: "Ripple is installed." / "The installer, \u201CRipple.dmg\u201D, is still open. You do not need it now. Move it to the Trash? This also ejects it." Buttons "Move to Trash" and "Keep".
- Access: Return moves it to the Trash; the alert reads aloud as written.
Status: done
Note: Ripple finds the installer by asking macOS which file an open disk image came from. It never looks inside your Downloads folder, so macOS does not show an access prompt for that. If the disk image was already ejected, Ripple cannot know where the file is and asks nothing. The Trash move itself is the real NSWorkspace call; the self-test makes its own disk images and never touches one you opened yourself (an earlier version of the test could see your real installer; see the fix log).

### S-035 Link the app to its web page
As the user, I can open Ripple's web page and its privacy page from the app.
Screens: (menu bar, About window)
Depends: S-005
Acceptance:
- [self] The website link is a secure address on bradysbit.com, and the privacy page is a secure address beside it.
- [manual] Help > Ripple Website and Help > Privacy and Terms open those pages in the browser; the About window shows both as links.
Status: done
Note: Ripple is free. The web page carries a Ko-fi tip link and a privacy and terms page that says what the app sends (a disc lookup to MusicBrainz, the Cover Art Archive, and Apple's iTunes Search) and what it keeps (nothing but settings on the Mac). The Help menu and About window also link to the Ko-fi tip page; the app never asks for a tip on its own. The privacy page's contact is BradysBit's Ko-fi page.

## Dropped
- Accounts, sync, sharing, and teams: Ripple has one user and no server.
- A file-name template editor: the default `Artist/Album/01 - Title` handles multi-disc and compilations.
- Upgrade prompts, analytics, and onboarding screens: nothing to sell or track.
- Multi-drive parallel ripping: one disc at a time in version one.

## Later
- CD-Text and burning M4A files.
- AccurateRip verification and a drive offset database.
- Cue sheets, single-image rips, CUETools DB, C2 pointers, HTOA, ReplayGain.
- FLAC, ALAC, WavPack, and other lossless formats.
- Discogs or GnuDB as a second metadata source, and the iTunes Search API for art.
- Re-tagging existing files and batch library tools.
- iCloud sync of settings.
