#!/usr/bin/env python3
"""Real Ctrl-H/J/K/L through Godot and tmux with a private session owner."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer

directory = Path(tempfile.mkdtemp(prefix="gft-tmux-nav-", dir="/tmp"))
print("Evidence:", directory, flush=True)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("GRAFFITTY_", "CODEX_")) and key not in ("TMUX", "TMUX_PANE")}
for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
    env["XDG_" + kind + "_HOME"] = str(directory / kind.lower())
env["GRAFFITTY_SERVER__NAVIGATOR__ENABLED"] = "true"
with PrivateServer(env, directory, "/bin/sh"):
    with (directory / "godot.log").open("w") as log:
        result = subprocess.run([
            "godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
            "--script", "res://tests/tmux_navigator_smoke.gd", "--", "--shell=/bin/sh", *sys.argv[1:],
        ], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
    output = (directory / "godot.log").read_text()
    print(output)
    assert result.returncode == 0 and "REPLAY_PASS" in output
