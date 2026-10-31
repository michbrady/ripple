#!/usr/bin/env python3
"""Builds ../index.html from page.html: inlines the screenshots and fills in the download's size and checksum.

Usage: python3 website/source/build.py     (run from the repo root; website/Ripple.dmg must exist)
"""
import base64, hashlib, os, re, subprocess, urllib.parse

here = os.path.dirname(os.path.abspath(__file__))
site = os.path.dirname(here)

logo = '''<svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Ripple logo">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2bb1cf"/><stop offset="1" stop-color="#0a8aa8"/></linearGradient></defs>
<rect width="1024" height="1024" rx="230" fill="url(#g)"/>
<g fill="#fff" fill-rule="evenodd" opacity=".6">
<path d="M512 172 a340 340 0 1 0 0.01 0 Z M512 202 a310 310 0 1 1 -0.01 0 Z"/>
<path d="M512 92 a420 420 0 1 0 0.01 0 Z M512 120 a392 392 0 1 1 -0.01 0 Z"/></g>
<path fill="#fff" fill-rule="evenodd" d="M512 244 a268 268 0 1 0 0.01 0 Z M512 436 a76 76 0 1 1 -0.01 0 Z"/>
</svg>'''

def image(name):
    with open(os.path.join(here, "shots", name + ".png"), "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()

dmg_path = os.path.join(site, "Ripple.dmg")
data = open(dmg_path, "rb").read()
size_mb = len(data) / 1_000_000

# The page says "notarized" only when Apple's ticket is really stapled to this file.
notarized = subprocess.run(["xcrun", "stapler", "validate", dmg_path], capture_output=True).returncode == 0
STEP3 = (
    '<li><h3>Open Ripple</h3><p>Open Ripple from Applications. It is signed and notarized by Apple, so it opens without a warning. '
    'The first time, macOS may ask you to confirm that it came from the internet: choose <b>Open</b>.</p></li>'
) if notarized else (
    '<li><h3>Open it once</h3><p>Open Ripple from Applications. macOS will say it cannot check Ripple for malware, because this early '
    'version is not notarized by Apple yet. Open <b>System Settings</b>, choose <b>Privacy &amp; Security</b>, scroll to Security, '
    'and choose <b>Open Anyway</b>. You only do this the first time.</p></li>'
)
NOTARY_BULLET = (
    '<li><b>Signed and notarized.</b> Apple has checked this download for known malicious software.</li>'
) if notarized else (
    '<li><b>Not notarized.</b> That is why macOS asks you to allow it. A notarized download is planned.</li>'
)

page = open(os.path.join(here, "page.html")).read()
fills = {
    "FAVICON": urllib.parse.quote(logo.replace("\n", ""), safe=""),
    "LOGO": logo,
    "DL_SIZE": f"{size_mb:.1f} MB",
    "DL_SHA": hashlib.sha256(data).hexdigest(),
    "INSTALLER": image("installer"),
    "STEP3": STEP3,
    "NOTARY_BULLET": NOTARY_BULLET,
    "TRACKS_LIGHT": image("tracks-light"), "TRACKS_DARK": image("tracks-dark"),
    "PICKER_LIGHT": image("picker-light"), "PICKER_DARK": image("picker-dark"),
    "BURN_LIGHT": image("burn-list-light"), "BURN_DARK": image("burn-list-dark"),
}
for key, value in fills.items():
    page = page.replace("{{%s}}" % key, value)
assert "{{" not in page, "an unfilled placeholder is left"
out = os.environ.get("PAGE_OUT") or os.path.join(site, "index.html")
open(out, "w").write(page)
# The privacy page: the same styling and logo as the main page, so the two always match.
style = re.search(r"<style>(.*?)</style>", page, re.S).group(1)
privacy = open(os.path.join(here, "privacy.html")).read()
for key, value in {"STYLE": style, "LOGO": logo, "FAVICON": fills["FAVICON"]}.items():
    privacy = privacy.replace("{{%s}}" % key, value)
assert "{{" not in privacy, "an unfilled placeholder is left in the privacy page"
# The pages must point at each other, and the tip link must be there.
assert 'href="privacy.html"' in page, "the main page does not link to the privacy page"
assert 'href="./"' in privacy, "the privacy page does not link back"
assert "https://ko-fi.com/bradysbit" in page, "the Ko-fi tip link is missing"
privacy_out = os.environ.get("PRIVACY_OUT") or os.path.join(site, "privacy.html")
open(privacy_out, "w").write(privacy)
print(f"wrote {privacy_out}")
print(f"download is {'signed and NOTARIZED' if notarized else 'not notarized'}")
print(f"wrote {out} ({len(page) // 1024} KB); Ripple.dmg is {fills['DL_SIZE']}, sha256 {fills['DL_SHA'][:16]}...")
