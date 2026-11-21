#!/usr/bin/env python3
"""Render connected tabs and exercise native window/session transfers privately."""

import argparse
import contextlib
import json
import os
import shutil
import subprocess
import time
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_background import background_failures, prepare_background
from e2e_server import PrivateServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument(
        "--scenario",
        choices=("all", "frame", "rapid-switch", "window", "merge", "placement", "close", "close-server", "close-bounds", "close-selection", "search"),
        default="all",
    )
    parser.add_argument(
        "--gpu",
        action="store_true",
        help="Use hidden native windows and Metal; required for frame pixels",
    )
    parser.add_argument("--godot", default=os.environ.get("GRAFFITTY_GODOT") or shutil.which("godot") or "godot")
    parser.add_argument("--headful", action="store_true", help="Render in the current desktop, including an isolated Linux virtual display")
    args = parser.parse_args()
    if args.scenario in ("all", "frame", "rapid-switch") and not args.gpu:
        parser.error("Frame pixel checks require --gpu")
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    results = []
    for scenario in (
        ("frame", "rapid-switch", "window", "merge", "placement", "close", "close-server", "close-bounds", "close-selection", "search") if args.scenario == "all" else (args.scenario,)
    ):
        evidence = directory / scenario
        evidence.mkdir()
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("GRAFFITTY_", "CODEX_"))
        }
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(evidence / kind.lower())
        env["GRAFFITTY_TEST_EVIDENCE"] = str(evidence)
        graphics = ([] if os.name == "nt" or args.headful else prepare_background(env, evidence / "guard")) if args.gpu else ["--headless"]
        shell = os.environ.get("GRAFFITTY_TEST_SHELL", "pwsh.exe" if os.name == "nt" else "/bin/sh")
        script = {
            "frame": "tab_frame_smoke",
            "rapid-switch": "rapid_tab_switch_smoke",
            "window": "tab_window_session_smoke",
            "merge": "tab_merge_preview_smoke",
            "placement": "tab_transfer_placement_smoke",
            "close": "window_close_smoke",
            "close-server": "window_close_smoke",
            "close-bounds": "tab_close_bounds_smoke",
            "close-selection": "tab_close_selection_smoke",
            "search": "tab_search_smoke",
        }[scenario]
        errors = []
        code = None
        try:
            with (
                (
                    PrivateServer(env, evidence, shell)
                    if scenario not in ("frame", "close-bounds")
                    else contextlib.nullcontext()
                ) as owner,
                (evidence / "godot.log").open("w") as log,
            ):
                run = subprocess.run(
                    [
                        args.godot,
                        *graphics,
                        "--path",
                        str(ROOT / "frontends/godot/project"),
                        "--script",
                        f"res://tests/{script}.gd",
                        "--",
                        "--shell=" + shell,
                        "--no-plugin",
                        *(["--close-server"] if scenario == "close-server" else []),
                    ],
                    env=env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=90,
                    check=False,
                )
                code = run.returncode
                if scenario == "close":
                    # Detaching the final window quits the app, never the server.
                    time.sleep(2)
                    if owner.process.poll() is not None or not owner.descriptor.exists():
                        errors.append("Detaching the final window stopped the owner")
                elif scenario in ("close-server", "close-selection"):
                    if owner.process.wait(timeout=5) != 0 or owner.descriptor.exists():
                        errors.append("Last session did not stop the owner cleanly")
        except (subprocess.TimeoutExpired, OSError, RuntimeError) as error:
            errors.append(str(error))
        log_text = (
            (evidence / "godot.log").read_text(encoding="utf-8", errors="replace")
            if (evidence / "godot.log").exists()
            else ""
        )
        marker = {
            "frame": "TAB_FRAME failures=0",
            "rapid-switch": "RAPID_TAB_SWITCH_PASS",
            "window": "TAB_WINDOW_SESSION failures=[]",
            "merge": "TAB_MERGE_PREVIEW_SMOKE_REPLAY_PASS",
            "placement": "TAB_TRANSFER_PLACEMENT failures=[]",
            "close": "WINDOW_CLOSE_PASS",
            "close-server": "WINDOW_CLOSE_PASS",
            "close-bounds": "TAB_CLOSE_BOUNDS failures=0",
            "close-selection": "TAB_CLOSE_SELECTION_PASS",
            "search": "TAB_SEARCH_SMOKE_REPLAY_PASS",
        }[scenario]
        if (
            code != 0
            or marker not in log_text
            or "ERROR:" in log_text
            or "FAIL " in log_text
        ):
            errors.append("Frontend checks failed; inspect godot.log")
        if args.gpu and sys.platform == "darwin" and not args.headful:
            errors.extend(background_failures(evidence / "guard"))
        results.append(
            {
                "scenario": scenario,
                "status": "FAIL" if errors else "PASS",
                "exit_code": code,
                "errors": errors,
            }
        )
    report = {
        "status": "FAIL" if any(r["status"] == "FAIL" for r in results) else "PASS",
        "results": results,
    }
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(directory)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
