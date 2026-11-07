# Fix log

Bugs found while building, newest first. Each ends with a rule.

## A Blu-ray image with video in it but an empty playlist (M8, found by reading the playlist, not by the test passing)
Symptom: The first Blu-ray build passed its test (image mounts, BDMV folders, a `.m2ts` stream) but the playlist file (`00000.mpls`) was 88 bytes, with no play items and one chapter mark. A player would show a disc with nothing to play.
Cause: tsMuxeR was given bare `.264` and `.ac3` files. It wrote the stream but could not read the clip's length, so the playlist came out empty and `--custom-chapters` was ignored.
Fix: ffmpeg writes one Matroska file per video (picture and sound together), and tsMuxeR joins them with `"a.mkv"+"b.mkv"`. The playlist then has its play item, and one chapter per video. The real-tools test now parses the playlist's chapter count and asks ffmpeg for the stream's codec, size, and length.
Rule: A test that finds files is not a test that finds a disc that plays. Read the part a player reads (here the playlist) and assert what it says.

## A test could have trashed my user's real installer (M6, caught before it did any harm)
Symptom: The installer-cleanup self-test recorded a "Keep" for `~/Downloads/Ripple.dmg`, a file the user had really downloaded and opened, and its later "yes" steps then failed.
Cause: The test asked the real finder for open disk images, and the finder returns the first Ripple installer it sees, which was the user's, not the test's. Only a faked "no" ran against it. A faked "yes" would have ejected and trashed the real file.
Fix: The test now sees only the disk images it made itself (filtered by their folder). A file opened twice is also handled: every copy is ejected.
Rule: A test that can eject, move, or delete must be unable to see anything it did not create. Filter the inputs, not just the outputs.

## A loose MusicBrainz match was filled in as if it were the album, and the right album ranked last (M5, found on the first real music CD)
Symptom: The disc "Songs for Silly Time" (Twin Sisters) was shown as "GrandMix Nouveau Disco" by Ben Liebrand, with wrong titles.
Cause: MusicBrainz had no record of this disc's exact ID, so the lookup fell back to a loose search by table of contents and returned six albums, all with 32 tracks. Ripple took the first as the answer without saying so. It ranked them by format and year, and the right album (no format, no year) came last.
Fix: Rank loose matches by how closely each track's length fits the disc (the right album: 0.03 s average off; the other five: 34 to 42 s off). A loose match is filled in only if every length fits (average under 1 s, worst under 3 s), and the window says it is not an exact disc match. Otherwise nothing is filled in and the user chooses ("No exact match for this disc. 6 possible albums").
Rule: Never present a guess as the answer. Say how sure you are, and rank by evidence (here, track lengths), not by tidy metadata.

## Checked rips were 6 times slower than needed (M4)
Symptom: A 105-second track took 67.6 s with Check for Errors on (1.6x real time), but 11 s with it off (9.5x).
Cause: Each 26-sector read was followed by a seek across the disc to clear the drive's cache.
Fix: Checked rips read 300 sectors at a time: 25.4 s (4.1x).
Rule: Measure on the real device before tuning. A cost per call, multiplied by a small chunk size, was the whole problem.

## My real-disc comparison called good audio bad (M5)
Symptom: The raw audio from the disc did not match the system's own copy, byte for byte.
Cause: The system's files are AIFC with compression type "sowt", which is already little-endian. My test swapped the bytes as if it were classic big-endian AIFF.
Fix: Read the compression type and swap only when needed. The audio then matched exactly: 300 sectors, 7 positioned reads, 40 scattered reads (12,000 sectors), and 6 cold starts.
Rule: Read a file's declared format before assuming it. One earlier run showed 18 differing sectors at the start of a read and could not be reproduced afterwards; it is recorded as unexplained, not fixed.

## MP3 Disc files were numbered twice: `01 - 01 - One.mp3` (M5, found by the first real burn)
Symptom: On the burned DVD-R every file name had the number twice.
Cause: The burner added "NN - " to each name, but ripped files already start with a number.
Fix: `BurnNaming` replaces an existing leading number (`07 - `, `7. `, `03_`) and keeps titles that merely begin with a number (`99 Luftballons`, `1979`).
Rule: Add a prefix only after checking whether the name already carries one. Run the real thing once on real media before trusting a fixture.

## The real-burn check failed with "the disc holds nothing" although the disc was fine (M5)
Symptom: After the burn the self-test listed the mounted disc as empty and reported four failures.
Cause: The volume appears in /Volumes before its files can be listed, and the check read it at once.
Fix: Wait until the listing has the expected files.
Rule: A mount point existing does not mean its contents are ready. Wait for the contents.

## Retracted: "the disc has the wrong filesystem" (M5)
I first read the HFS+ mount of the burned disc as meaning it had no ISO 9660 or Joliet. Reading the disc's raw sectors showed a full hybrid: ISO 9660, Joliet (long names), UDF, and HFS+. macOS simply prefers HFS+ when it mounts. No code changed.
Rule: Check what is on the media before blaming the way it was written.

## The same file was added to the burn list twice (M5)
Symptom: Dropping a file that was already in the list added it again.
Cause: Files were identified by their path as written. One reached the list as `/var/folders/...` (a dropped URL) and the other as `/private/var/folders/...` (from the folder scan): the same file through a link.
Fix: `BurnItem.id` is the resolved, standardized path.
Rule: Identify a file by its resolved path, never by the string a URL happened to carry.

## M4A tags failed: the moov box was not last (M3)
Symptom: The first M4A tagger threw `moovNotLast` for every file.
Cause: It assumed Core Audio writes `moov` at the end. Core Audio writes `ftyp`, `moov`, 56 KB of `free` padding, then `mdat`.
Fix: Rebuild the file with a new `moov`, drop the padding, and shift every `stco` and `co64` chunk offset by the distance `mdat` moved.
Rule: Never assume box order in an MP4. Dump the real layout first, and check the result by decoding the whole file, not just reading the tags.

## Snapshots showed the self-test's settings (M3)
Symptom: The snapshot's Output Folder read `ripple-self-<uuid>` and the quality read "Fixed 320 kbps".
Cause: Test runs shared one saved-settings store, and the self-test had written into it.
Fix: A test or snapshot run empties its settings store at launch.
Rule: Anything a test run writes must start from empty every time, so one run never leaks into the next.

## File names lost the space where a tab was (M1)
Symptom: A title with a tab came out as "HiddenSong", not "Hidden Song".
Cause: The cleaner deleted control characters before it treated whitespace as a separator, and a tab is both.
Fix: Whitespace becomes a space first; only other control characters are dropped.
Rule: Turn whitespace into spaces before stripping control characters.

## The release script rejected a correctly signed app (M6, found on the first real release)
Symptom: tools/release.sh stopped with "the hardened runtime is not on", but `codesign -dv` showed the app signed with it.
Cause: The check was `codesign -dv "$app" 2>&1 | grep -q runtime` under `set -o pipefail`. `grep -q` quits at its first match, which can kill `codesign` while it is still printing; the pipeline then reports failure although the text matched.
Fix: Read the whole output into a variable, then test it.
Rule: Never end a pipeline in `grep -q` in a script that uses pipefail. Capture the output, then match it.
(The "timestamps differ by 181 seconds" warning in the same run was only codesign waiting for the keychain prompt to be approved.)

## The release script died right after Apple accepted the app (M6, found on the first real release)
Symptom: `notarize:4: read-only variable: status`, immediately after Apple's answer. Apple's history showed the app Accepted.
Cause: In zsh, `status` is a special read-only variable (the same as `$?`). The script used it as an ordinary name.
Fix: Renamed it `verdict`.
Rule: In zsh scripts, never name a variable `status`, `path`, `argv`, `options`, `pipestatus`, or other shell built-ins. Check a new script by running it once end to end on a harmless input before relying on it.

## The first real dvdauthor run refused every menu button (M7, found when the real tools first ran)
Symptom: The disc build failed at "Writing the disc files": `That form of jumping is not allowed in VMGM pgc 0, button b1`.
Cause: Title buttons on the menu used `jump titleset 1 title N`. The stand-in tools in the tests never read the XML, so nothing caught it. The real dvdauthor accepts `jump title N` from the menu and refuses the longer form.
Fix: Title and Play All buttons now use `jump title N`. A test builds a real disc image with the real ffmpeg, spumux, dvdauthor, and hdiutil, mounts it, and checks VIDEO_TS (DVDRealBuildTests, skipped when the tools are not built).
Rule: A stand-in tool proves the order of steps, not that the real tool accepts what you give it. Run every external program for real once, in a test that skips when it is missing, before calling its step done.

