"""Write source.json: the SideStore/AltStore "source" that announces new builds.

SideStore polls this file; when `version` goes up it shows "Update available".
Usage: python make_source.py <version> <build_number> <ipa_path> <download_url> <out_path>
"""
import datetime
import json
import os
import sys

REPO = "angelorsbastos/extended_display"
SOURCE_URL = f"https://github.com/{REPO}/releases/latest/download/source.json"
ICON_URL = (f"https://raw.githubusercontent.com/{REPO}/main/"
            "ipad/ExtendDisplay/Assets.xcassets/AppIcon.appiconset/icon.png")

version, build, ipa_path, download_url, out_path = sys.argv[1:6]

source = {
    "name": "Extend Display",
    "identifier": "dev.extenddisplay.source",
    "sourceURL": SOURCE_URL,
    "iconURL": ICON_URL,
    "apps": [{
        "name": "Extend Display",
        "bundleIdentifier": "dev.extenddisplay.app",
        "developerName": "angelorsbastos",
        "subtitle": "Use the iPad as a second screen over USB.",
        "localizedDescription": "Receives a Windows monitor over the USB cable and shows it full-screen.",
        "iconURL": ICON_URL,
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "downloadURL": download_url,
            "size": os.path.getsize(ipa_path),
            "minOSVersion": "16.0",
        }],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}

with open(out_path, "w") as f:
    json.dump(source, f, indent=2)
print(f"wrote {out_path} for version {version} ({build})")
