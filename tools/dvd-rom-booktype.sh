#!/bin/zsh
# Asks the burner to label a blank DVD+R as a DVD-ROM ("bitsetting"), which some older DVD players need before they will play it.
# The tool talks to the drive with commands that differ by drive maker. It knows Ricoh, BenQ, BTC, NEC, Lite-On, LG and Plextor
# designs and nothing else, so this works only on those drives. The script checks that first, tries, and says plainly what happened.
#
# Usage:
#   tools/dvd-rom-booktype.sh --check     Reads the drive's current setting. Changes nothing. Also tells you if the drive is a kind the tool knows.
#   tools/dvd-rom-booktype.sh --set       Tells the drive to brand DVD+R discs as DVD-ROM.
#   tools/dvd-rom-booktype.sh --verify    After the burn: reads the finished disc and says what book type it has.
#   tools/dvd-rom-booktype.sh --restore   Puts the drive back to branding DVD+R as DVD+R.
# Option:  --device /dev/diskN   (when the drive is not found by itself)
#
# Needs the dvd+rw-tools programs:  brew install dvd+rw-tools
# Order: --check, --set, burn the disc (keep the drive plugged in and powered), --verify.
# The setting is in the drive, not on the disc, and most drives forget it when powered off.
set -uo pipefail

mode=""; device=""
while (( $# )); do
  case $1 in
    --check|--set|--verify|--restore) mode=${1#--} ;;
    --device) shift; device=${1:-} ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done
[[ -n "$mode" ]] || { print -u2 "Say what to do: --check, --set, --verify or --restore (try --help)."; exit 2 }

say()  { print -r -- "$*" }
fail() { print -u2 -r -- "FAILED: $*"; exit 1 }
stop() { print -u2 -r -- "CANNOT DO THIS: $*"; exit 3 }

[[ $(uname) == Darwin ]] || fail "this script is for a Mac."
for tool in dvd+rw-booktype; do
  command -v $tool >/dev/null || fail "$tool is not installed. Run: brew install dvd+rw-tools"
done

# 1. The drive and the disc in it.
dstat=$(drutil status 2>&1)
if [[ "$dstat" == *"No Drive"* || -z "$dstat" ]]; then fail "no disc drive is connected. Plug in the burner and try again."; fi
if [[ "$dstat" == *"No Media"* || "$dstat" == *"No media"* ]]; then fail "there is no disc in the drive. Insert a blank DVD+R."; fi
media_type=$(print -r -- "$dstat" | sed -n 's/.*Type: *\([^ ]*\).*/\1/p' | head -1)
[[ -n "$device" ]] || device=$(print -r -- "$dstat" | grep -o '/dev/disk[0-9]*' | head -1)
[[ -n "$device" ]] || fail "could not find the disc's device name. Run drutil status, then pass it with --device /dev/diskN."
raw=${device/\/dev\/disk//dev/rdisk}
vendor=$(print -r -- "$dstat" | awk 'NR==2 {print}' | sed 's/^ *//')
say "Drive:  ${vendor:-unknown}"
say "Disc:   ${media_type:-unknown}  ($device)"

if [[ $mode != verify && "$media_type" != DVD+R* ]]; then
  stop "the disc is ${media_type:-unknown}, not a DVD+R or DVD+RW. DVD-R discs already work this way and cannot be changed. Insert a blank DVD+R."
fi

unknown_family() { [[ "$1" == *"doesn't appear to be one"* ]] }
unknown_text="This drive is not one of the kinds the tool knows (Ricoh, BenQ, BTC, NEC, Lite-On, LG, Plextor), so it cannot be changed from here. Use a DVD-R."

# 2. What the drive says it does now. This reads the setting with the drive maker's own command, so a good answer
#    means the tool knows this drive. It still cannot prove the drive will accept a change.
inq=$(dvd+rw-booktype -inq -unit+r "$raw" 2>&1); inq_status=$?
say ""; say "What the drive reports:"
print -r -- "$inq" | sed 's/^/   /'
disc=$(dvd+rw-booktype -inq -media "$raw" 2>&1)
print -r -- "$disc" | sed 's/^/   /'

if [[ $mode == check ]]; then
  say ""
  if unknown_family "$inq"; then say "RESULT: $unknown_text"; exit 1; fi
  if [[ "$inq" == *"will brand DVD+R"* ]]; then
    say "RESULT: the tool knows this drive. Next: tools/dvd-rom-booktype.sh --set"
    say "        Not every firmware version accepts the change, so only --set shows it for sure."
    exit 0
  fi
  say "RESULT: the drive did not report its setting (exit $inq_status). It probably cannot be changed. Use a DVD-R."
  exit 1
fi

if [[ $mode == verify ]]; then
  say ""
  if [[ "$disc" == *"DVD-ROM"* ]]; then say "RESULT: the disc is labeled DVD-ROM."; exit 0; fi
  say "RESULT: the disc is not labeled DVD-ROM. Read the Book Type line above."
  say "        If it says DVD+R, the drive did not apply the setting. Use a DVD-R instead."
  exit 1
fi

# 3. Try the change. For DVD+R it is a setting in the drive ("-unit+r"); "-media" works only on DVD+RW discs.
diskutil unmountDisk "$device" >/dev/null 2>&1 || true
if [[ $mode == restore ]]; then book=-dvd+r; else book=-dvd-rom; fi
if [[ "$media_type" == DVD+RW* ]]; then target=-media; else target=-unit+r; fi
say ""; say "Asking the drive: dvd+rw-booktype $book $target $raw"
out=$(dvd+rw-booktype $book $target "$raw" 2>&1); code=$?
print -r -- "$out" | sed 's/^/   /'
if unknown_family "$out"; then say ""; say "RESULT: $unknown_text"; exit 1; fi
if (( code != 0 )); then
  say ""
  say "RESULT: the drive REFUSED the change (exit $code). Its firmware does not allow it."
  say "        Nothing was written to the disc. Use a name-brand DVD-R instead; it works in more old players."
  exit 1
fi

say ""; say "After the change:"
dvd+rw-booktype -inq -unit+r "$raw" 2>&1 | sed 's/^/   /'
say ""
if [[ $mode == restore ]]; then say "RESULT: the drive is back to branding DVD+R as DVD+R."; exit 0; fi
say "RESULT: the drive accepted the change."
say "NEXT: burn the disc now. Keep the drive plugged in and powered: most drives forget the setting when powered off."
say "      Then run: tools/dvd-rom-booktype.sh --verify   (you may have to insert the finished disc again)"
say "      Whether the burn keeps the setting is not proven until --verify says the disc is labeled DVD-ROM."
