# Ripple web page

Upload these two files to the same folder on the web server (for example `bradysbit.com/ripple/`):

- `index.html` is the whole page. The screenshots, logo, and styles are inside it.
- `Ripple.zip` is the download. The page links to it as `Ripple.zip`, so it must sit next to `index.html`.

`Ripple.zip` is not kept in git. To make a new one and update the page (size and checksum are filled in for you):

```sh
./build.sh                                  # build the app into ~/Applications
ditto -c -k --sequesterRsrc --keepParent ~/Applications/Ripple.app website/Ripple.zip
python3 website/source/build.py             # rewrites website/index.html
```

The page's text is in `website/source/page.html`; screenshots are in `website/source/shots/`.
Before sharing widely: set `LiveLookup.contact` in `Sources/Ripple/Disc/AlbumLookup.swift`, then rebuild the zip.
