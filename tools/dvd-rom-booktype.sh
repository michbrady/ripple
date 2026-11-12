#!/bin/zsh
# Asks the burner to label a blank DVD+R as a DVD-ROM ("bitsetting"), which some older DVD players need before they will play it.
# Whether this works is up to the burner's firmware. This script checks first, tries, and says plainly what happened.
#
# Usage:
#   tools/dvd-rom-booktype.sh --check     Looks at the drive and disc and changes nothing.
#   tools/dvd-rom-booktype.sh --set       Asks the drive to use the DVD-ROM book type for the blank disc in it.
#   tools/dvd-rom-booktype.sh --verify    After the burn: reads the finished disc and says what book type it has.
# Options: --device /dev/diskN   (when the drive is not found by itself)
#          --permanent           (--set only) change the drive's own default instead of this one disc. Undo with --restore.
#          --restore             Put the drive's default back to DVD+R.
#
# Needs the dvd+rw-tools programs:  brew install dvd+rw-tools
# Order: --check, --set, burn the disc without taking it out of the drive, --verify.
set -uo pipefail

mode=""; device=""; permanent=0
while (( $# )); do
  case $1 in
    --check|--set|--verify|--restore) mode=${1#--} ;;
    --permanent) permanent=1 ;;
    --device) shift; device=${1:-} ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done
[[ -n "$mode" ]] || { print -u2 "Say what to do: --check, --set, or --verify (try --help)."; exit 2 }

say()  { print -r -- "$*" }
fail() { print -u2 -r -- "FAILED: $*"; exit 1 }
stop() { print -u2 -r -- "CANNOT DO THIS: $*"; exit 3 }

[[ $(uname) == Darwin ]] || fail "this script is for a Mac."
for tool in dvd+rw-booktype dvd+rw-mediainfo; do
  command -v $tool >/dev/null || fail "$tool is not installed. Run: brew install dvd+rw-tools"
done

# 1. The drive and the disc in it.
status=$(drutil status 2>&1)
if [[ "$status" == *"No Drive"* || -z "$status" ]]; then fail "no disc drive is connected. Plug in the burner and try again."; fi
if [[ "$status" == *"No Media"* || "$status" == *"No media"* ]]; then fail "there is no disc in the drive. Insert a blank DVD+R."; fi
media_type=$(print -r -- "$status" | sed -n 's/.*Type: *\([^ ]*\).*/\1/p' | head -1)
[[ -n "$device" ]] || device=$(print -r -- "$status" | grep -o '/dev/disk[0-9]*' | head -1)
[[ -n "$device" ]] || fail "could not find the disc's device name. Run drutil status, then pass it with --device /dev/diskN."
raw=${device/\/dev\/disk//dev/rdisk}
vendor=$(print -r -- "$status" | awk 'NR==2 {print}' | sed 's/^ *//')
say "Drive:  ${vendor:-unknown}"
say "Disc:   ${media_type:-unknown}  ($device)"

if [[ $mode != verify && $mode != restore && "$media_type" != DVD+R* ]]; then
  stop "the disc is ${media_type:-unknown}, not a DVD+R or DVD+RW. DVD-R discs already work this way and cannot be changed. Insert a blank DVD+R."
fi

show_book() {   # the book type lines the drive reports, as they are
  dvd+rw-mediainfo "$raw" 2>&1 | grep -iE "book|mounted media|media id|disc status" | sed 's/^/   /'
}

# 2. What the drive says it can do.
say ""; say "What the drive reports:"
inq=$(dvd+rw-booktype -inq "$raw" 2>&1); inq_status=$?
print -r -- "$inq" | sed 's/^/   /'
show_book

if [[ $mode == check ]]; then
  say ""
  if (( inq_status != 0 )); then
    say "RESULT: the drive did not answer the book type query ($inq_status). It probably cannot change the book type. Use a DVD-R instead."
    exit 1
  fi
  say "RESULT: the drive answered. This does not prove it will accept the change, because only trying shows that. Next: tools/dvd-rom-booktype.sh --set"
  exit 0
fi

if [[ $mode == verify ]]; then
  say ""
  if dvd+rw-mediainfo "$raw" 2>&1 | grep -iE "book" | grep -qi "DVD-ROM"; then
    say "RESULT: the disc is labeled DVD-ROM."; exit 0
  fi
  say "RESULT: the disc does not say DVD-ROM in its book type. Read the lines above to see what it says."
  say "         If it says DVD+R, the setting was lost before or during the burn. Use a DVD-R instead."
  exit 1
fi

# 3. Try the change.
diskutil unmountDisk "$device" >/dev/null 2>&1 || true
if [[ $mode == restore ]]; then flags=(-dvd+r-spec -unit+r); else
  flags=(-dvd-rom); (( permanent )) && flags+=(-unit) || flags+=(-media)
fi
say ""; say "Asking the drive: dvd+rw-booktype ${flags[*]} $raw"
out=$(dvd+rw-booktype "${flags[@]}" "$raw" 2>&1); code=$?
print -r -- "$out" | sed 's/^/   /'
if (( code != 0 )); then
  say ""
  say "RESULT: the drive REFUSED the change (exit $code). Its firmware does not allow it."
  say "        Nothing was written to the disc. Use a name-brand DVD-R instead; it works in more old players."
  exit 1
fi

say ""; say "After the change:"; show_book
say ""
if [[ $mode == restore ]]; then say "RESULT: the drive default is back to DVD+R."; exit 0; fi
say "RESULT: the drive accepted the change."
say "NEXT: burn the disc now WITHOUT taking it out of the drive (taking it out loses the setting unless you used --permanent),"
say "      then run: tools/dvd-rom-booktype.sh --verify"
say "      Whether the burn keeps the setting is not proven until --verify says the disc is labeled DVD-ROM."
