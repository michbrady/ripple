# Ripple web page

Upload these two files to the same folder on the web server (for example `bradysbit.com/ripple/`):

- `index.html` is the whole page. The screenshots, logo, and styles are inside it.
- `Ripple.dmg` is the download: an installer disk image with Ripple and an Applications folder to drag it onto.
  The page links to it as `Ripple.dmg`, so it must sit next to `index.html`.

`Ripple.dmg` is not kept in git. To make a new one and update the page (size and checksum are filled in for you):

```sh
./build.sh                       # build the app into ~/Applications
tools/make-dmg.sh                # pack it into website/Ripple.dmg (lets Finder lay out the window)
python3 website/source/build.py  # rewrites website/index.html
```

The page's text is in `website/source/page.html`; screenshots are in `website/source/shots/`.
The picture on the installer window is drawn by `tools/dmg-background.swift`.
Before sharing widely: set `LiveLookup.contact` in `Sources/Ripple/Disc/AlbumLookup.swift`, then rebuild.
