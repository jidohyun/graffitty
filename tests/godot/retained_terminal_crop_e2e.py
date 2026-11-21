#!/usr/bin/env python3
"""Render the 11-tab world-switch crop regression on an isolated owner."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures
from e2e_bistro import installed_bistro, link_bistro


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--godot", default=os.environ.get("GRAFFITTY_TEST_GODOT", "godot"))
    parser.add_argument("--headful", action="store_true")
    args = parser.parse_args()
    directory = args.evidence.resolve()
    # The test switches to Bistro by id, so it needs the installed pack.
    bistro = installed_bistro()
    directory.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    link_bistro(directory / "data", bistro)
    env["GRAFFITTY_CROP_EVIDENCE"] = str(directory)
    shell = "pwsh.exe" if os.name == "nt" else "/bin/sh"
    if os.name == "nt" and not args.headful:
        parser.error("Windows rendering requires --headful")
    with PrivateServer(env, directory, shell):
        flags = [] if args.headful else prepare_background(env, directory / "gpu")
        with (directory / "godot.log").open("w") as log:
            result = subprocess.run([args.godot, "--path", str(ROOT / "frontends/godot/project"),
                *flags, "--script", "res://tests/retained_terminal_crop_smoke.gd", "--",
                "--no-plugin", "--shell=" + shell], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        text = (directory / "godot.log").read_text(encoding="utf-8")
        assert result.returncode == 0 and "TERMINAL_CROP_PASS" in text, text
        assert "SCRIPT ERROR:" not in text and "ERROR:" not in text, text
        if not args.headful:
            assert not background_failures(directory / "gpu"), "Background rendering guard failed"
        assert json.loads((directory / "result.json").read_text())["passed"]
    print("TERMINAL_CROP_E2E_PASS", directory)


if __name__ == "__main__":
    main()
