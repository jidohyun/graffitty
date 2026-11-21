#!/usr/bin/env python3
"""Rebuild the preserved Windows CEF capture fork in an existing pinned checkout.

No checkout resets, downloads, or changes to installed browsers. The archive in
fork/cef/artifacts/windows-x64 normally makes this multi-hour build unnecessary.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(__doc__)
parser.add_argument(
    "--source-root",
    type=Path,
    required=True,
    help="Chromium src directory containing cef/",
)
parser.add_argument("--depot-tools", type=Path, required=True)
parser.add_argument("--jobs", type=int, default=8)
args = parser.parse_args()
if sys.platform != "win32":
    parser.error("Run on Windows with the Chromium MSVC build environment configured")
if args.jobs < 1:
    parser.error("--jobs must be positive")
source = args.source_root.resolve()
revision = subprocess.check_output(
    ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
).strip()
if revision != "86539fc5de947c93970452ebcc56eb68a36f7ce2":
    raise SystemExit("Chromium revision does not match the preserved Windows runtime")
patches = Path(__file__).resolve().parent
subprocess.run(
    [
        sys.executable,
        str(patches / "apply_windows.py"),
        str(source / "cef"),
        "--patch-dir",
        str(patches),
    ],
    check=True,
)
out = source / "out" / "Release_GN_x64"
if not (out / "build.ninja").is_file():
    raise SystemExit(
        "Configure this pinned checkout with CEF automate-git first; see README.md"
    )


def gn_args(path):
    values = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


# The recorded configuration is the release configuration: refuse a checkout
# whose GN arguments differ (for example, one built with fatal DCHECKs).
recorded, actual = gn_args(patches / "args.gn"), gn_args(out / "args.gn")
different = {key: (value, actual.get(key)) for key, value in recorded.items() if actual.get(key) != value}
if different:
    raise SystemExit(
        f"{out / 'args.gn'} differs from {patches / 'args.gn'}: "
        + ", ".join(f"{key}={want} (found {have})" for key, (want, have) in sorted(different.items()))
    )
env = os.environ.copy()
env.pop("PYTHONUTF8", None)  # Chromium ACL scripts must use the host code page.
env.update(DEPOT_TOOLS_WIN_TOOLCHAIN="0", DEPOT_TOOLS_UPDATE="0")
env["PATH"] = str(args.depot_tools.resolve()) + os.pathsep + env["PATH"]
subprocess.run(
    [
        str(args.depot_tools.resolve() / "autoninja.bat"),
        "-C",
        str(out),
        "-j",
        str(args.jobs),
        "libcef",
        "bootstrap",
        "bootstrapc",
    ],
    env=env,
    check=True,
)
print(
    f"Built Windows CEF in {out}; package and revalidate before replacing the pinned asset."
)
