#!/usr/bin/env python3
"""Check the installed app's layout and native chromium provenance."""

import os
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleExecutable"] == "Graffitty"
assert info["CFBundleIdentifier"] == "dev.graffitty.terminal"
assert info["NSServices"] == [{
    "NSMenuItem": {"default": "Open in Graffitty"},
    "NSMessage": "openFolders",
    "NSPortName": "Graffitty",
    "NSSendTypes": ["NSFilenamesPboardType"],
    "NSSendFileTypes": ["public.folder"],
    "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
}], "Missing or incorrect Finder Service declaration"
root = app / "Contents/Resources/graffitty"
assert (app / "Contents/Resources/GraffittyRuntime.pck").resolve() == root / "terminal.pck"
assert (app / "Contents/Frameworks/addons").resolve() == root / "addons"
for name in [
    "terminal.pck",
    "tools/gft-gui",
    "tools/gft",
    "skills/terminal-chromium/SKILL.md",
    "skills/graffitty/SKILL.md",
    "addons/graffitty/bin/libgraffitty.macos.dylib",
]:
    assert (root / name).is_file(), name
assert os.readlink(root / "tools/gft-gui") == "gft", "gft-gui must be a link to gft, not a copy"
assert not (root / "worlds").exists(), "Worlds are external resources selected by user config"
host = root / "Chromium GPU Host.app"
assert (host / "Contents/MacOS/probe").is_file()
assert (
    host
    / "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
).is_file()
assert "sha256=" in (host / "Contents/Resources/custom-cef-source.txt").read_text()
assert (
    root / "chromium-host-path.txt"
).read_text().strip() == "Chromium GPU Host.app/Contents/MacOS/probe"
assert (app / "Contents/Resources/Graffitty.icns").read_bytes()[:4] == b"icns"
subprocess.run(
    [str(app / "Contents/MacOS/Graffitty"), "--help"],
    check=True,
    stdout=subprocess.DEVNULL,
)
subprocess.run([str(root / "tools/gft"), "node", "parallel", "--help"], check=True, stdout=subprocess.DEVNULL)
subprocess.run([str(root / "tools/gft-gui"), "--help"], check=True, stdout=subprocess.DEVNULL)
subprocess.run([str(root / "tools/gft"), "server", "--help"], check=True, stdout=subprocess.DEVNULL)
subprocess.run([str(app / "Contents/MacOS/GraffittyRuntime"), "--version"], check=True)
subprocess.run([
    sys.executable,
    str(pathlib.Path(__file__).resolve().parents[2] / "tests/chromium/chromium_nested_bundle_e2e.py"),
    str(host),
], check=True)
print("GRAFFITTY_PACKAGE_PASS")
