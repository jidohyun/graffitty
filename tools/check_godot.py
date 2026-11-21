"""Run Godot's parser without opening a window or running the application."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "frontends/godot/project"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def failed(returncode: int, output: str) -> bool:
    output = ANSI.sub("", output)
    return returncode != 0 or bool(
        re.search(
            r"(?m)^\s*(?:SCRIPT ERROR:|ERROR:|Parse Error:|Compile Error:)", output
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "scripts", nargs="*", help="Optional res:// or project-relative .gd paths"
    )
    args = parser.parse_args()
    base = [os.environ.get("GODOT", "godot"), "--headless", "--path", str(PROJECT)]
    if args.scripts:
        commands = [
            base + ["--check-only", "--script", script] for script in args.scripts
        ]
    else:
        scripts = sorted(
            "res://" + str(path.relative_to(PROJECT)).replace("\\", "/")
            for directory in [
                "scenes",
                "config",
                "graffitty",
                "tests",
                "tools",
                "addons/source_assets",
                "worlds",
            ]
            for path in (PROJECT / directory).rglob("*.gd")
            if ".godot" not in path.parts
        )
        commands = [
            base + ["--editor", "--import"],
            base + ["--script", "res://tools/check_scripts.gd", "--", *scripts],
        ]
    with tempfile.TemporaryDirectory(prefix="graffitty-script-check-") as scratch:
        env = dict(os.environ)
        for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
            env[f"XDG_{kind}_HOME"] = str(Path(scratch) / kind.lower())
        if not args.scripts:
            # A manifest avoids OS command-line length limits in larger projects.
            import json

            manifest = Path(scratch) / "scripts.json"
            manifest.write_text(json.dumps(scripts))
            commands[-1] = base + [
                "--script",
                "res://tools/check_scripts.gd",
                "--",
                str(manifest),
            ]
        return run_checks(commands, env)


def run_checks(commands: list[list[str]], env: dict[str, str]) -> int:
    errors = False
    for command in commands:
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        print(result.stdout, end="")
        errors |= failed(result.returncode, result.stdout)
    print("FAIL: Godot reported errors" if errors else "PASS: Godot script check")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
