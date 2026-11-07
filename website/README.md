# Ripple web page

Upload these three files to the same folder on the web server (`bradysbit.com/ripple/`):

- `index.html` is the whole page. The screenshots, logo, and styles are inside it.
- `privacy.html` is the privacy and terms page. The app's Help menu and About window link to it by this name,
  so it must sit next to `index.html`.
- `Ripple.dmg` is the download: an installer disk image with Ripple and an Applications folder to drag it onto.
  The page links to it as `Ripple.dmg`, so it must sit next to `index.html`.

**Do not upload this page version yet.** `page.html` and `privacy.html` now describe the Video DVD feature (2026-11-07), but the released `Ripple.dmg` does not have it. Upload them together with a new `Ripple.dmg` made after the DVD build and burn work (stories S-045 to S-048: build, burn, and carrying ffmpeg and dvdauthor with their licences). The "early version" list on the page says a Video DVD has not been tried on a real disc yet; update it once one has.

`Ripple.dmg` is not kept in git. To make a new one and update the page (size and checksum are filled in for you):

```sh
./build.sh                       # build the app into ~/Applications
tools/make-dmg.sh                # pack it into website/Ripple.dmg (lets Finder lay out the window)
python3 website/source/build.py  # rewrites website/index.html
```

The page's text is in `website/source/page.html`; screenshots are in `website/source/shots/`.
The picture on the installer window is drawn by `tools/dmg-background.swift`.
Before sharing widely: set `LiveLookup.contact` in `Sources/Ripple/Disc/AlbumLookup.swift`, then rebuild.
