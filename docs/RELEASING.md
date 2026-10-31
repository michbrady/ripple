# Releasing Ripple: signing and notarizing

Goal: a download that opens with no "cannot verify" warning. Apple does this in two parts. **Signing** proves
the app comes from your Apple Developer account. **Notarizing** has Apple scan it and attach a ticket.

Today the app is signed only ad hoc, so macOS asks people to use Open Anyway. After the steps below,
`tools/release.sh` does everything in one command.

## One-time setup (only you can do this: it uses your Apple account)

You need a paid Apple Developer Program membership (an individual account is fine) that has finished enrolling.

**1. Sign in to Xcode.** Xcode > Settings > Accounts > + > Apple ID. Sign in with your developer Apple ID.

**2. Make the signing certificate.** In Accounts, select your team, click **Manage Certificates…**, click **+**, and
choose **Developer ID Application**. (Only the account holder or an admin can.) Check it worked:

```sh
security find-identity -v -p codesigning
#   1) ABC123... "Developer ID Application: Your Name (TEAMID)"
```

The ten letters and numbers in brackets are your **Team ID**.

**3. Make an app-specific password.** Go to account.apple.com, Sign-In and Security, App-Specific Passwords, and make
one called "Ripple notarization". Apple shows it once. This is *not* your Apple ID password, and you can revoke it later.

**4. Save the login in your keychain.** In Terminal (or in Claude Code, typing `!` first), run the command below.
It will ask you to paste the app-specific password; type it there and nowhere else.

```sh
xcrun notarytool store-credentials ripple-notary --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID"
```

Never paste the password into a chat or a file in the project.

## Every release

```sh
tools/release.sh
```

It checks the setup, builds with the hardened runtime, signs, sends the app to Apple and waits (a few minutes),
attaches Apple's ticket, packs and signs the installer, notarizes that too, asks macOS to judge the result, and rebuilds
the web page. The page says "signed and notarized" only when the ticket is really attached to `website/Ripple.dmg`.

Then upload `website/index.html` and `website/Ripple.dmg`.

If Apple says no, the script prints Apple's own explanation and stops.

## Notes

- **Hardened runtime.** Notarization requires it. Ripple passes its whole self-test under it. Reading and burning real
  discs under it still need one check on real hardware (the drive was unplugged when this was set up).
- **LAME is a separate library inside the app** (Contents/Frameworks/libmp3lame.0.dylib), which is what the LGPL asks for.
  Its licence and a source notice are in Contents/Resources/Licenses, and the About window and web page say so.
- **The hardened runtime only loads libraries signed by Apple or the same team.** With your Developer ID both Ripple and
  libmp3lame carry your team, so it should load. An ad hoc signature has no team, so `HARDENED=1 ./build.sh` on its own
  makes the app fail to start with "Library not loaded": that is expected and only affects that test. `tools/release.sh` runs
  the app's self-test from the signed app and stops if it fails. If it ever says "Library not loaded" with your real certificate,
  use the fallback it names: `ENTITLEMENTS=tools/fallback.entitlements tools/release.sh`.
- **Bundle identifier.** It is `com.michael.ripple`. Changing it later resets people's saved settings.
