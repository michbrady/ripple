#!/bin/zsh
# Builds the installer disk image, website/Ripple.dmg: a window with Ripple and an Applications
# folder, an arrow between them, and Ripple's icon on the disk. People drag one onto the other.
#
# Run ./build.sh first: this packs ~/Applications/Ripple.app.
# Usage: tools/make-dmg.sh [output.dmg]        (default website/Ripple.dmg)
set -euo pipefail
here=${0:A:h:h}
app="$HOME/Applications/Ripple.app"
out=${1:-$here/website/Ripple.dmg}
volume="Ripple"
[[ -d "$app" ]] || { echo "no $app: run ./build.sh first"; exit 1; }

# Finder lays out the window, so the working copy must mount in /Volumes where Finder can see it.
mount="/Volumes/$volume"
[[ ! -e "$mount" ]] || { echo "a disk named $volume is already mounted: eject it first"; exit 1; }
work=$(mktemp -d)
trap 'hdiutil detach "$mount" -quiet -force 2>/dev/null || true; rm -rf "$work"' EXIT

# 1. The picture behind the icons, at 1x and 2x, joined into one file Finder picks from.
swiftc -O "$here/tools/dmg-background.swift" -o "$work/dmg-background" 2>/dev/null
"$work/dmg-background" "$work/bg.png" "$work/bg@2x.png"
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/background.tiff" >/dev/null

# 2. A blank, writable disk image, mounted where we can reach it.
size_mb=$(( $(du -sm "$app" | cut -f1) * 2 + 20 ))
hdiutil create -size ${size_mb}m -fs HFS+ -volname "$volume" -ov "$work/rw.dmg" >/dev/null
hdiutil attach "$work/rw.dmg" -noautoopen -quiet
[[ -d "$mount" ]] || { echo "the working disk did not mount at $mount"; exit 1; }
sleep 1

# 3. The contents: the app, a shortcut to /Applications, the background, and the disk's icon.
ditto "$app" "$mount/Ripple.app"
ln -s /Applications "$mount/Applications"
mkdir "$mount/.background"
cp "$work/background.tiff" "$mount/.background/background.tiff"
cp "$app/Contents/Resources/AppIcon.icns" "$mount/.VolumeIcon.icns"
SetFile -c icnC "$mount/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "$mount" 2>/dev/null || true

# 4. The window: icon view, no toolbar, the picture, and the two icons where the arrow points.
#    This asks Finder to lay it out, so macOS may ask once to let this script control Finder.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 800, 540}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 128
    set text size of theOptions to 13
    set background picture of theOptions to file ".background:background.tiff"
    set position of item "Ripple.app" of container window to {160, 200}
    set position of item "Applications" of container window to {440, 200}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder did not lay out the window (allow it in System Settings > Privacy & Security > Automation). The disk image still works, with a plain layout."
fi
sync; sleep 1
hdiutil detach "$mount" -quiet

# 5. Shrink it into the final, read-only file.
mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out" >/dev/null
hdiutil verify "$out" -quiet && echo "built $out ($(du -h "$out" | cut -f1)), verified"
