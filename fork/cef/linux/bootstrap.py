#!/usr/bin/env python3
"""Fetch a new pinned Linux CEF workspace; existing workspaces are never reset."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import urllib.request

from build import PINS, defines


def run(*args, **kwargs):
    print("+", *map(str, args), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--arch", choices=("x64", "arm64"), required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or platform.machine() != "x86_64":
        parser.error("The pinned Chromium tools require an x64 Linux host")
    work = args.work_root.resolve()
    if work.exists() or any(c.isspace() for c in str(work)):
        parser.error("Use a new, nonexistent workspace path without whitespace")
    work.mkdir(parents=True)
    url = f"https://raw.githubusercontent.com/chromiumembedded/cef/{PINS['cef']}/tools/automate/automate-git.py"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != PINS["automate_sha256"]:
        raise SystemExit("Upstream automate-git.py checksum mismatch")
    script = work / "automate-git.py"
    script.write_bytes(data)
    depot = work / "depot_tools"
    run("git", "clone", "https://chromium.googlesource.com/chromium/tools/depot_tools.git", depot)
    run("git", "-C", depot, "checkout", "--detach", PINS["depot_tools"])
    env = dict(os.environ, DEPOT_TOOLS_UPDATE="0",
               GN_DEFINES=defines(args.arch), GN_OUT_CONFIGS=f"Release_GN_{args.arch}",
               PATH=str(depot) + os.pathsep + os.environ["PATH"])
    run(depot / "ensure_bootstrap", cwd=depot, env=env)
    run(sys.executable, script, f"--download-dir={work}", f"--depot-tools-dir={depot}",
        "--url=https://github.com/chromiumembedded/cef.git",
        f"--checkout={PINS['cef']}", f"--chromium-checkout={PINS['chromium_ref']}",
        f"--branch={PINS['branch']}", f"--{args.arch}-build", "--no-chromium-history",
        "--no-depot-tools-update", "--no-build", "--no-distrib", env=env)
    for tree, key in [(work / "chromium/src", "chromium"),
                      (work / "chromium/src/cef", "cef"), (depot, "depot_tools")]:
        revision = subprocess.check_output(["git", "-C", str(tree), "rev-parse", "HEAD"], text=True).strip()
        if revision != PINS[key]:
            raise SystemExit(f"Incorrect {key} revision; inspect the workspace before proceeding")
    (work / "bootstrap.json").write_text(json.dumps({
        "pins": {key: PINS[key] for key in ("cef", "chromium", "depot_tools")}
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
