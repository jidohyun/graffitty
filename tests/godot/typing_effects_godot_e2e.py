#!/usr/bin/env python3
"""Real pane title layout and focus cancellation with a private session owner."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer

directory = Path(tempfile.mkdtemp(prefix="gft-typing-effects-"))
godot = os.environ.get("GRAFFITTY_TEST_GODOT", os.environ.get("GRAFFITTY_GODOT", "godot"))
shell = "pwsh.exe" if os.name == "nt" else os.environ.get("SHELL", "/bin/sh")
print("Evidence:", directory, flush=True)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("GRAFFITTY_", "CODEX_")) and key not in ("TMUX", "TMUX_PANE")}
for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
    env["XDG_" + kind + "_HOME"] = str(directory / kind.lower())
with PrivateServer(env, directory, shell):
    with (directory / "godot.log").open("w", encoding="utf-8") as log:
        result = subprocess.run([
            godot, "--headless", "--path", str(ROOT / "frontends/godot/project"),
            "--script", "res://tests/typing_effects_focus_smoke.gd", "--", *sys.argv[1:],
        ], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
    output = (directory / "godot.log").read_text(encoding="utf-8")
    print(output)
    assert result.returncode == 0 and "REPLAY_PASS" in output
