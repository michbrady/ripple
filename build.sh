#!/bin/zsh
# Builds Ripple and installs it to ~/Applications/Ripple.app.
# Build products live in ~/Library/Developer/Ripple, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="Ripple"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

"$here/tools/build-lame.sh"   # LAME is a separate library inside the app (LGPL)
swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# LAME goes in as its own file, next to the program, with its licence and notice.
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
cp "$here/.lame/libmp3lame.0.dylib" "$app/Contents/Frameworks/"
cp "$here/vendor/lame/LICENSE-LAME.txt" "$here/vendor/lame/LAME-NOTICE.txt" "$app/Contents/Resources/Licenses/"
# ffmpeg, the program that reads videos, goes in as its own file when tools/fetch-ffmpeg.sh has fetched it (S-048 adds the rest of the DVD tools and the credits).
if [[ -x "$here/.dvdtools/ffmpeg" ]]; then
  mkdir -p "$app/Contents/Resources/bin"
  cp "$here/.dvdtools/ffmpeg" "$app/Contents/Resources/bin/ffmpeg"
fi
# dvdauthor and spumux (tools/build-dvdauthor.sh) go in with the few libraries they need, with all three programs' licences.
dvdbin="$here/.dvdtools/dvdauthor"
if [[ -x "$dvdbin/bin/dvdauthor" && -x "$dvdbin/bin/spumux" ]]; then
  mkdir -p "$app/Contents/Resources/bin" "$app/Contents/Resources/lib"
  cp "$dvdbin/bin/dvdauthor" "$dvdbin/bin/spumux" "$app/Contents/Resources/bin/"
  cp "$dvdbin/lib/"*.dylib "$app/Contents/Resources/lib/"
fi
# tsMuxeR (tools/fetch-tsmuxer.sh) writes the Blu-ray disc image.
if [[ -x "$here/.dvdtools/tsMuxeR" ]]; then
  mkdir -p "$app/Contents/Resources/bin"
  cp "$here/.dvdtools/tsMuxeR" "$app/Contents/Resources/bin/tsMuxeR"
fi
if [[ -d "$app/Contents/Resources/bin" ]]; then
  cp "$here/vendor/dvdtools/"* "$app/Contents/Resources/Licenses/"
fi
# The build links a path on this Mac so `swift run` works; a finished app must not carry it.
install_name_tool -delete_rpath "$here/.lame" "$app/Contents/MacOS/$name" 2>/dev/null || true
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
xattr -cr "$app"
# A Developer ID signature needs the hardened runtime and a secure timestamp, or Apple will not notarize it.
# HARDENED=1 turns the hardened runtime on for any signature, to test it.
flags=()
if [[ "$identity" == Developer\ ID* || "${HARDENED:-}" == 1 ]]; then flags=(--options runtime --timestamp); fi
[[ "$identity" == "-" ]] && flags=(${flags:#--timestamp})   # an ad hoc signature cannot be timestamped
# Sign the library first, then the app that holds it.
codesign --force "${flags[@]}" --sign "$identity" "$app/Contents/Frameworks/libmp3lame.0.dylib" 2>&1 | grep -v "replacing existing signature" || true
# Programs and libraries inside the app are signed first, then the app that holds them.
for inner in "$app"/Contents/Resources/lib/*.dylib "$app"/Contents/Resources/bin/*(N); do
  [[ -f "$inner" ]] && { codesign --force "${flags[@]}" --sign "$identity" "$inner" 2>&1 | grep -v "replacing existing signature" || true; }
done
ents=()
[[ -n "${ENTITLEMENTS:-}" ]] && ents=(--entitlements "$ENTITLEMENTS")   # see tools/fallback.entitlements
codesign --force "${flags[@]}" "${ents[@]}" --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
