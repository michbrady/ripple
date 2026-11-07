#!/bin/zsh
# Builds dvdauthor and spumux (GPL) from the official source into .dvdtools/dvdauthor/, as standalone programs
# that carry their own copies of the libraries they need and nothing that decrypts DVDs.
#
# Run it once: tools/build-dvdauthor.sh        (add --install-deps to let it run `brew install` for the build tools)
# Needs Homebrew only to get the BUILD tools (pkgconf, libpng, freetype). The finished programs do not use Homebrew:
# their libraries are copied next to them and rewired. libdvdcss (copy-protection decryption) is never copied or linked.
set -euo pipefail
here=${0:A:h:h}
out="$here/.dvdtools/dvdauthor"
work="$here/.dvdtools/src"
version=0.7.2
tarball="dvdauthor-$version.tar.gz"
url="https://downloads.sourceforge.net/project/dvdauthor/$tarball"
sha256="3020a92de9f78eb36f48b6f22d5a001c47107826634a785a62dfcd080f612eb7"   # the checksum Homebrew pins for this file
die() { print -u2 "build-dvdauthor: $*"; exit 1 }

[[ -x "$out/bin/dvdauthor" && -x "$out/bin/spumux" && "${1:-}" != "--force" ]] && { print "already built: $out (use --force to rebuild)"; exit 0 }

# 1. The build tools.
command -v brew >/dev/null || die "Homebrew is needed to get the build tools (pkgconf, libpng, freetype). See https://brew.sh"
need=()
for pkg in pkgconf libpng freetype; do brew list --versions "$pkg" >/dev/null 2>&1 || need+=("$pkg"); done
if (( ${#need} )); then
  if [[ " $* " == *" --install-deps "* ]]; then brew install "${need[@]}"
  else die "missing build tools: ${need[*]}. Run:  brew install ${need[*]}   (or run this script again with --install-deps)"; fi
fi
prefix=$(brew --prefix)

# 2. The source, checked against the published checksum.
mkdir -p "$work"
if [[ ! -f "$work/$tarball" ]]; then
  print "downloading $url"
  curl -fL --progress-bar -o "$work/$tarball" "$url"
fi
actual=$(shasum -a 256 "$work/$tarball" | cut -d' ' -f1)
[[ "$actual" == "$sha256" ]] || { rm -f "$work/$tarball"; die "the download does not match the expected checksum ($actual). Deleted it. Nothing was built."; }
print "checksum ok"
rm -rf "$work/dvdauthor-$version" "$work/dvdauthor"
tar -xzf "$work/$tarball" -C "$work"
# The 0.7.2 tarball unpacks to dvdauthor/, not dvdauthor-0.7.2/.
[[ -d "$work/dvdauthor-$version" ]] || mv "$work/dvdauthor" "$work/dvdauthor-$version"

# 3. Build. The flags only quiet warnings that this 2010 code triggers under a modern compiler.
cd "$work/dvdauthor-$version"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=26.0 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-function-pointer-types -Wno-deprecated-declarations"
rm -rf "$out"
./configure --prefix="$out" --disable-dependency-tracking --disable-dvdunauthor > "$work/configure.log" 2>&1 || { tail -25 "$work/configure.log" >&2; die "configure failed (full log: $work/configure.log)"; }
make -j"$(sysctl -n hw.ncpu)" > "$work/make.log" 2>&1 || { tail -25 "$work/make.log" >&2; die "make failed (full log: $work/make.log)"; }
make install > "$work/install.log" 2>&1 || { tail -25 "$work/install.log" >&2; die "make install failed (full log: $work/install.log)"; }

# 4. Make the programs stand alone: copy every non-system library next to them and point the programs at the copies.
mkdir -p "$out/lib"
typeset -A done
fix() {   # fix <file>: copy its Homebrew dependencies into lib/ and rewrite the names, recursively
  local file=$1 dep base
  for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -E "^($prefix|/opt/homebrew|/usr/local|@rpath/)" || true); do
    base=${dep:t}
    src=$dep
    # An @rpath name (Homebrew's brotli) is found in Homebrew's own library folders.
    [[ "$dep" == @rpath/* ]] && src=$(ls "$prefix"/opt/*/lib/"$base" 2>/dev/null | head -1)
    [[ -n "$src" && -e "$src" ]] || die "$file needs $dep, which was not found in Homebrew's folders"
    [[ "$base" != *dvdcss* ]] || die "$file links libdvdcss ($dep). That library decrypts copy-protected DVDs and must not be bundled."
    if [[ -z "${done[$base]:-}" ]]; then
      done[$base]=1
      cp -L "$src" "$out/lib/$base"; chmod u+w "$out/lib/$base"
      install_name_tool -id "@loader_path/$base" "$out/lib/$base"
      fix "$out/lib/$base"
    fi
    if [[ "$file" == "$out/lib/"* ]]; then install_name_tool -change "$dep" "@loader_path/$base" "$file"
    else install_name_tool -change "$dep" "@executable_path/../lib/$base" "$file"; fi
  done
}
for tool in "$out"/bin/*(N); do
  [[ -x "$tool" ]] && fix "$tool"
done
# Anything left that points outside the system, or at libdvdcss, is a mistake.
for f in "$out"/bin/* "$out"/lib/*.dylib; do
  [[ -f "$f" ]] || continue
  bad=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE "^(/usr/lib/|/System/|@loader_path/|@executable_path/)" || true)
  [[ -z "$bad" ]] || die "$f still depends on: $bad"
done
for f in "$out"/lib/*.dylib "$out"/bin/*; do [[ -f "$f" ]] && codesign --force --sign - "$f" 2>/dev/null; done
cp "$work/dvdauthor-$version/COPYING" "$out/LICENSE-dvdauthor.txt" 2>/dev/null || true
rm -rf "$out/share/man" 2>/dev/null || true

# 5. Does it run?
for tool in dvdauthor spumux; do
  banner=$("$out/bin/$tool" --help 2>&1 || true)   # they print their version, then complain about --help, with various exit codes
  [[ "$banner" == *"version $version"* ]] || die "$tool does not start"
  print "ok: $tool"
done
print "built $out"
print "bundled libraries: $(ls "$out/lib" | tr '\n' ' ')"
