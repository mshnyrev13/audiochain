#!/usr/bin/env python3
"""Validate release inputs and prepare the two public GitHub assets."""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent

def main():
    release = json.loads((ROOT / "Distribution/release.json").read_text())
    version = release["version"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise SystemExit("Invalid stable version")
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version or release["tag"] != "v" + version or release["file"] != "AudioChain.dmg":
        raise SystemExit("Release metadata mismatch")
    source = ROOT / "Distribution/AudioChain.dmg"
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != release["sha256"]:
        raise SystemExit("DMG checksum mismatch")
    output = pathlib.Path(os.environ["RUNNER_TEMP"]) / "audiochain-release"
    output.mkdir(exist_ok=True)
    name = f"AudioChain-{version}.dmg"
    shutil.copyfile(source, output / name)
    (output / "SHA256SUMS").write_text(f"{digest}  {name}\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write(f"version={version}\ntag=v{version}\n")
    print(f"Verified AudioChain {version}: SHA256 {digest}")

if __name__ == "__main__":
    main()
