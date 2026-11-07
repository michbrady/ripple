#!/bin/zsh
# Downloads tsMuxeR (Apache 2.0, from github.com/justdan96/tsMuxer) into .dvdtools/tsMuxeR, checked against a known checksum.
# It joins the converted videos into a Blu-ray disc image. Ripple runs it as a separate program.
# Usage: tools/fetch-tsmuxer.sh        (skips it when already there; --force downloads again)
set -euo pipefail
here=${0:A:h:h}
dest="$here/.dvdtools/tsMuxeR"
version=2.7.0
sha256="bf90b608321f491b955fd9432000a8370c048e9c306e3a5833dfd75e5fa530e1"   # tsMuxer-2.7.0-mac.zip
mkdir -p "${dest:h}"
if [[ -x "$dest" && "${1:-}" != "--force" ]]; then print "already there: $dest"; exit 0; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar -o "$tmp/tsmuxer.zip" "https://github.com/justdan96/tsMuxer/releases/download/$version/tsMuxer-$version-mac.zip"
[[ "$(shasum -a 256 "$tmp/tsmuxer.zip" | cut -d' ' -f1)" == "$sha256" ]] || { print -u2 "the download does not match the expected checksum. Nothing was installed."; exit 1; }
unzip -oq "$tmp/tsmuxer.zip" -d "$tmp"
mv "$tmp/tsMuxeR" "$dest"; chmod +x "$dest"; xattr -c "$dest" 2>/dev/null || true
file "$dest" | grep -q arm64 || { print -u2 "this tsMuxeR is not an Apple silicon program"; exit 1; }
print "ok: tsMuxeR $version"
