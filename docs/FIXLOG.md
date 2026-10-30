# Fix log

Bugs found while building, newest first. Each ends with a rule.

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
