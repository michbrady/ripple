#!/bin/zsh
# Downloads the static ffmpeg (GPL build from ffmpeg.martin-riedl.de) into .dvdtools/ffmpeg.
# It converts videos to DVD format and makes the menu pictures into video. Ripple runs it as a separate program.
# Usage: tools/fetch-ffmpeg.sh        (skips it when already there; --force downloads again)
set -euo pipefail
here=${0:A:h:h}
dest="$here/.dvdtools/ffmpeg"
mkdir -p "${dest:h}"
if [[ -x "$dest" && "${1:-}" != "--force" ]]; then print "already there: $dest ($("$dest" -version | head -1))"; exit 0; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar -o "$tmp/ffmpeg.zip" https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip
unzip -oq "$tmp/ffmpeg.zip" -d "$tmp"
mv "$tmp/ffmpeg" "$dest"; chmod +x "$dest"; xattr -c "$dest" 2>/dev/null || true
for enc in mpeg2video ac3; do "$dest" -hide_banner -encoders 2>/dev/null | grep -q " $enc " || { print -u2 "this ffmpeg lacks the $enc encoder"; exit 1; }; done
print "ok: $("$dest" -version | head -1)"
