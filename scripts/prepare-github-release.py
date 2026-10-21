#!/usr/bin/env python3
"""Stage a reviewed local DMG for the repository's release workflow."""
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 scripts/prepare-github-release.py /path/to/AudioChain-VERSION.dmg")
    source = pathlib.Path(sys.argv[1]).resolve(strict=True)
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise SystemExit("Invalid stable version")
    if source.name != f"AudioChain-{version}.dmg" or not source.is_file():
        raise SystemExit("DMG filename must match Info.plist version")
    directory = ROOT / "Distribution"
    directory.mkdir(exist_ok=True)
    destination = directory / "AudioChain.dmg"
    if source != destination:
        shutil.copyfile(source, destination)
    manifest = {"version": version, "tag": "v" + version, "file": "AudioChain.dmg",
                "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}
    (directory / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Staged AudioChain {version}: SHA256 {manifest['sha256']}")

if __name__ == "__main__":
    main()
