#!/bin/zsh
# Signs Ripple with your Developer ID, has Apple notarize it, and packs the installer for the web page.
#
# One-time setup, which only you can do (it uses your Apple account): see docs/RELEASING.md.
#   1. A "Developer ID Application" certificate in your keychain (Xcode > Settings > Accounts > Manage Certificates).
#   2. A saved notarization login: xcrun notarytool store-credentials ripple-notary ...
#
# Usage: tools/release.sh
# Optional: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   NOTARY_PROFILE=ripple-notary
set -euo pipefail
here=${0:A:h:h}
cd "$here"
profile=${NOTARY_PROFILE:-ripple-notary}
die() { print -u2 "release: $*"; exit 1 }

# 1. Is everything in place? Say exactly what is missing, before any slow work.
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)}
[[ -n "$identity" ]] || die "no \"Developer ID Application\" certificate in your keychain. Create one in Xcode (Settings > Accounts > your team > Manage Certificates > + > Developer ID Application). See docs/RELEASING.md."
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
  || die "no saved notarization login named \"$profile\". Run: xcrun notarytool store-credentials $profile --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID  (it asks for an app-specific password). See docs/RELEASING.md."
print "signing as: $identity"
print "notarizing with the saved login: $profile"

# 2. Build and sign with the hardened runtime and a secure timestamp.
SIGN_IDENTITY="$identity" ./build.sh
app="$HOME/Applications/Ripple.app"
codesign --verify --deep --strict "$app"
# Read the whole output first: `codesign | grep -q` can fail under pipefail when grep quits early.
signature=$(codesign -dv "$app" 2>&1)
[[ "$signature" == *"(runtime)"* ]] || die "the hardened runtime is not on: Apple would reject this."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Does the signed app really start and make MP3s? Under the hardened runtime an app may only load libraries signed by
# Apple or by the same team, and LAME is a separate library. Find out now, not after Apple has the file.
run_selftest() {
  local result
  result=$(APP_STORE="$work/self.store" "$app/Contents/MacOS/Ripple" --selftest 2>&1 | tail -3 | tr '\n' ' ')
  [[ "$result" == *"SELFTEST PASS"* ]] || die "the signed app failed its own self-test: $result
If this says \"Library not loaded\" for libmp3lame, sign again with the fallback: ENTITLEMENTS=tools/fallback.entitlements tools/release.sh"
  print "the signed app passes its self-test."
}
run_selftest

# Sends a file to Apple and waits. Stops with Apple's own explanation if it is not accepted.
notarize() {
  local file=$1 json verdict id
  print "sending $(basename "$file") to Apple (this takes a few minutes)..."
  json=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json)
  verdict=$(print -r -- "$json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  id=$(print -r -- "$json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
  if [[ "$verdict" != "Accepted" ]]; then
    print -u2 "Apple said: $verdict. Its explanation:"
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    die "notarization of $(basename "$file") failed."
  fi
  print "Apple accepted $(basename "$file")."
}

# 3. Notarize the app, then attach Apple's ticket to it so it opens offline too.
ditto -c -k --keepParent "$app" "$work/Ripple.zip"
notarize "$work/Ripple.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
run_selftest   # once more with Apple's ticket attached

# 4. Pack the stapled app into the installer, sign that, notarize it, and staple it.
SIGN_IDENTITY="$identity" tools/make-dmg.sh
notarize website/Ripple.dmg
xcrun stapler staple website/Ripple.dmg
xcrun stapler validate website/Ripple.dmg

# 5. Ask macOS itself, the way a downloaded copy would be judged.
spctl --assess --type execute -vv "$app"
spctl --assess --type open --context context:primary-signature -vv website/Ripple.dmg

# 6. Update the web page: size, checksum, and wording that says it is notarized.
python3 website/source/build.py
print "done. Upload website/index.html and website/Ripple.dmg."
