#!/bin/zsh
# Builds LAME as a separate dynamic library, .lame/libmp3lame.0.dylib, from the sources in vendor/lame.
# Ripple links it at run time instead of compiling it in: LAME is LGPL, and a separate library can be replaced.
# ./build.sh runs this for you. Run it yourself before `swift build` or `swift test`.
set -euo pipefail
here=${0:A:h:h}
src="$here/vendor/lame"
out="$here/.lame"
lib="$out/libmp3lame.0.dylib"
mkdir -p "$out"

# Up to date? Then nothing to do.
if [[ -f "$lib" && -z "$(find "$src" -type f \( -name '*.c' -o -name '*.h' \) -newer "$lib" | head -1)" && "$0" -ot "$lib" ]]; then
  exit 0
fi

clang -arch arm64 -mmacosx-version-min=26.0 -O3 -dynamiclib -w \
  -DHAVE_CONFIG_H -I"$src" -I"$src/include" "$src"/*.c \
  -install_name @rpath/libmp3lame.0.dylib -compatibility_version 1.0.0 -current_version 3.100.0 \
  -o "$lib"
# `-lmp3lame` looks for the name without a version.
ln -sf libmp3lame.0.dylib "$out/libmp3lame.dylib"
echo "built $lib ($(du -h "$lib" | cut -f1))"
