#!/usr/bin/env python3
"""Check Bistro's 14 -> 13 tab arrival on an isolated owner with the installed pack."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tests/support")]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures
from e2e_bistro import installed_bistro, link_bistro


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--godot", default=os.environ.get("GRAFFITTY_TEST_GODOT", "godot"))
    parser.add_argument("--headful", action="store_true", help="Show the window and save arrival frames")
    args = parser.parse_args()
    directory = args.evidence.resolve()
    bistro = installed_bistro()
    directory.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    link_bistro(directory / "data", bistro)
    if args.headful:
        env["GRAFFITTY_TAB_ARRIVAL_ARTIFACTS"] = str(directory / "frames")
    shell = "pwsh.exe" if os.name == "nt" else "/bin/sh"
    if os.name == "nt" and not args.headful:
        parser.error("Windows rendering requires --headful")
    with PrivateServer(env, directory, shell):
        flags = [] if args.headful else prepare_background(env, directory / "gpu")
        with (directory / "godot.log").open("w") as log:
            result = subprocess.run([args.godot, "--path", str(ROOT / "frontends/godot/project"),
                *flags, "--script", "res://tests/bistro_tab_arrival_smoke.gd", "--",
                "--no-plugin", "--shell=" + shell], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        text = (directory / "godot.log").read_text(encoding="utf-8")
        assert result.returncode == 0 and "FAIL " not in text, text
        assert "SCRIPT ERROR:" not in text, text
        if not args.headful:
            assert not background_failures(directory / "gpu"), "Background rendering guard failed"
    print("BISTRO_TAB_ARRIVAL_E2E_PASS", directory)


if __name__ == "__main__":
    main()
