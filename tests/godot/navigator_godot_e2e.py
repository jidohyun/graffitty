#!/usr/bin/env python3
"""Real Ctrl-H/J/K/L through Godot, Fyler's mappings, and gft at editor edges."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer  # noqa: E402

root = Path(tempfile.mkdtemp(prefix="gft-nav-ui-", dir="/tmp"))
print("Evidence:", root, flush=True)
env = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(("GRAFFITTY_", "CODEX_")) and k not in ("TMUX", "TMUX_PANE")
}
(root / "home").mkdir()
env["HOME"] = str(root / "home")
for key in ("CONFIG", "STATE", "DATA", "CACHE"):
    env["XDG_" + key + "_HOME"] = str(root / key.lower())
env["GRAFFITTY_SERVER__NAVIGATOR__ENABLED"] = "true"
with PrivateServer(env, root, "/bin/zsh"):
    with (root / "godot.log").open("w") as log:
        result = subprocess.run(
            [
                "godot",
                "--headless",
                "--path",
                str(ROOT / "frontends/godot/project"),
                "--script",
                "res://tests/navigator_smoke.gd",
                "--",
                "--shell=/bin/zsh",
                *sys.argv[1:],
            ],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=100,
        )
    output = (root / "godot.log").read_text()
    print(output)
    assert result.returncode == 0 and "REPLAY_PASS" in output
print("NAVIGATOR_GODOT_PASS")
