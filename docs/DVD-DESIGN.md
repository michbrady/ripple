# Video DVD: how Ripple would make one

Goal: the user drops in video files (.mov, .mp4, .m4v, .avi, .mkv, .wmv, ...) and Ripple makes a standard DVD-Video disc with a menu it draws itself, then burns it. It plays in any DVD player.

## The pipeline

```text
video files
  1. Read each file          ffmpeg reads it: length, size, frame rate, audio. Unreadable or copy-protected files are named and left out.
  2. Plan the disc           sizes, a bit rate that makes everything fit, NTSC or PAL, 4:3 or 16:9. Pure logic, in RippleKit.
  3. Convert each title      ffmpeg -> MPEG-2 video + AC-3 audio in a DVD program stream (.mpg). The slow step.
  4. Draw the menu           Swift/Core Graphics: a background picture, a thumbnail and a name per title, Play All, pages when there are many.
                             ffmpeg turns it into a short MPEG-2 still with silent audio. Button highlight pictures are drawn too.
  5. Add the buttons         spumux (part of dvdauthor) lays the highlight pictures over the menu video.
  6. Author the disc         dvdauthor writes VIDEO_TS (IFO, BUP, VOB files) with the menu, titles, and chapters.
  7. Make the disc image     hdiutil makehybrid -udf -udf-version 1.02 -iso: the format DVD players read.
  8. Burn                    DiscRecording burns the image (a new DiscBurner method), with verify, then ejects.
```

Steps 3 to 7 write only into a work folder, which is deleted after the burn. A "Save Disc Image" choice stops after step 7 and needs no drive.

## What Ripple needs to carry

| Part | Where from | Notes |
| --- | --- | --- |
| ffmpeg | the static GPL build MegMusic already uses (ffmpeg.martin-riedl.de) | Has the MPEG-2 and AC-3 encoders, the DVD muxer, and every common reader. Checked on this Mac. |
| dvdauthor and spumux | built from source by `tools/build-dvdauthor.sh` into `.dvdauthor/` | Homebrew's build links libdvdcss (copy-protection decryption). Ripple's build must not: build with libpng and freetype only. |
| hdiutil, DiscRecording | macOS | Already there. |

Both programs are GPL. They would ship as separate programs inside the app (Contents/Resources/bin), signed with Ripple's hardened runtime and a timestamp, with their licences and source links in the About window and on the web page. Ripple itself stays as it is. LAME stays an LGPL library.

## Sizes and quality

- A single-layer DVD-R holds 2,298,496 blocks of 2,048 bytes (about 4.7 GB). A dual-layer disc holds about 8.5 GB. The disc in the drive says which.
- Audio is AC-3 at 192 kbit/s. Video gets what is left: `(blocks * 2048 * 8 * 0.97 - menu) / seconds - audio`, capped at 9,000 kbit/s.
- Quality bands for the capacity bar: 5,000 kbit/s or more Excellent (up to about 1 h 50 min on one layer), 3,500 or more Good (about 2 h 40), 2,500 or more Reduced (about 3 h 40), under that Too long.
- Menu pages hold 6 titles. Chapters every 5 minutes inside each title.

## What cannot be promised

- **Copy-protected video** (movies bought or rented from stores, streaming downloads) cannot be read. Ripple says so and does not try to get around it.
- **Playback has not been seen yet.** This Mac has no DVD Player and no burner is plugged in. Everything up to the disc image can be checked here: the structure with dvdauthor's own reader, the streams with ffmpeg, the image by mounting it. Whether a player shows the menu and its buttons correctly, and whether the burn works, needs a real burner, a blank DVD-R or DVD-RW, and a DVD player (a set-top player or VLC on the Mac).
- **Converting is slow.** A two-hour movie takes roughly 20 to 40 minutes on an Apple silicon Mac.

## Decisions

1. Bundle ffmpeg, dvdauthor, and spumux inside Ripple as separate GPL programs, with credits. (Needed for the feature at all.)
2. NTSC by default (US), PAL when the source is 25 or 50 frames a second, with a choice in the window.
3. Menu look: automatic, in Ripple's own style, with the disc's name at the top. No templates to pick in version one.
4. Version one leaves out: subtitles, extra audio tracks, custom menu pictures or music, DVD-9 disc splitting, and Blu-ray.
