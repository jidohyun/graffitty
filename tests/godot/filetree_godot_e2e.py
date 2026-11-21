#!/usr/bin/env python3
"""Exercise real prefix input, filetree links and force animation in Godot."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/android", "tests/support")]
from e2e_server import PrivateServer
from e2e_background import prepare_background


def main():
    root = Path(tempfile.mkdtemp(prefix="graffitty-filetree-godot-"))
    print("Evidence:", root, flush=True)
    if "--android" in sys.argv:
        from test_android_runtime import headless_fixture, simulate
        # Placement needs a live PTY, not a Neovim/plugin installation.
        executable = root / "filetree-terminal"
        executable.write_text("#!/bin/sh\nexec sleep 180\n")
        executable.chmod(0o700)
        fixture = root / "viewer.txt"
        fixture.write_text("File viewer placement fixture\n")
        with patch.dict(os.environ, {"GRAFFITTY_SERVER__FILETREE__COMMAND": json.dumps([str(executable)])}), headless_fixture(None, root) as connection:
            connection.update(filetree_fixture=str(fixture))
            simulate(root, {"connection": connection, "scenario": "filetree_layout", "case": "filetree-layout"})
        (root / "result.json").write_text(json.dumps({"status": "PASS"}))
        print("Android filetree placement PASS")
        return
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    home = root / "home"
    home.mkdir()
    env["HOME"] = str(home)
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    selected = root / "viewer.txt"
    selected.write_text("Filetree viewer fixture\n")
    Path(str(selected) + ".html").write_text('<!doctype html><textarea>preview selection</textarea>')
    env.update(GRAFFITTY_FILETREE_TEST_FILE=str(selected), GRAFFITTY_FILETREE_TEST_SCREENSHOT=str(root / "filetree.png"))
    with PrivateServer(env, root, "/bin/zsh"):
        gpu_args = prepare_background(env, root / "native") if "--gpu" in sys.argv else ["--headless"]
        with (root / "godot.log").open("w") as log:
            result = subprocess.run(["godot", *gpu_args, "--path", str(ROOT / "frontends/godot/project"),
                                     "--script", "res://tests/filetree_smoke.gd", "--", "--shell=/bin/zsh"],
                                    env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        output = (root / "godot.log").read_text()
        print(output)
        assert result.returncode == 0 and "REPLAY_PASS" in output
    (root / "result.json").write_text(json.dumps({"status": "PASS"}))


if __name__ == "__main__":
    main()
