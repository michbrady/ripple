#!/usr/bin/env python3
"""Builds ../index.html from page.html: inlines the screenshots and fills in the download's size and checksum.

Usage: python3 website/source/build.py     (run from the repo root; website/Ripple.dmg must exist)
"""
import base64, hashlib, os, urllib.parse

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

page = open(os.path.join(here, "page.html")).read()
fills = {
    "FAVICON": urllib.parse.quote(logo.replace("\n", ""), safe=""),
    "LOGO": logo,
    "DL_SIZE": f"{size_mb:.1f} MB",
    "DL_SHA": hashlib.sha256(data).hexdigest(),
    "INSTALLER": image("installer"),
    "TRACKS_LIGHT": image("tracks-light"), "TRACKS_DARK": image("tracks-dark"),
    "PICKER_LIGHT": image("picker-light"), "PICKER_DARK": image("picker-dark"),
    "BURN_LIGHT": image("burn-list-light"), "BURN_DARK": image("burn-list-dark"),
}
for key, value in fills.items():
    page = page.replace("{{%s}}" % key, value)
assert "{{" not in page, "an unfilled placeholder is left"
out = os.path.join(site, "index.html")
open(out, "w").write(page)
print(f"wrote {out} ({len(page) // 1024} KB); Ripple.dmg is {fills['DL_SIZE']}, sha256 {fills['DL_SHA'][:16]}...")
