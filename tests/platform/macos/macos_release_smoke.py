#!/usr/bin/env python3
"""Launch the packaged macOS release with its own CLI, extension and private server."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from packaged_probe import write_probe

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
args = parser.parse_args()
app = args.app.resolve()
runtime = app / "Contents/MacOS/GraffittyRuntime"
directory = Path(tempfile.mkdtemp(prefix="gft-release-smoke-", dir="/tmp"))
print("Evidence:", directory, flush=True)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("GRAFFITTY_", "CODEX_")) and key not in ("TMUX", "TMUX_PANE")}
for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
    env["XDG_" + kind + "_HOME"] = str(directory / kind.lower())
probe = write_probe(directory / "release-probe.gd", """
print("RELEASE_RUNTIME=", OS.has_feature("template_release"), " DEBUG=", OS.is_debug_build())
if DirAccess.dir_exists_absolute("res://worlds"):
	push_error("App pack must not contain external worlds")
for path in ["res://scenes/FlatTerminalSpaceWorld.gd", "res://scenes/Flat2DWorld.gd"]:
	if not ResourceLoader.exists(path):
		push_error("Missing built-in world: " + path)
var icon = preload("res://scenes/PaneIcons.gd").filetree()
if icon.get_source().is_empty() or icon.get_width() <= 0:
	push_error("Packaged filetree icon needs its SVG source")
""")
wrapper = directory / "runtime"
wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(runtime)) + ' --headless --quit-after 180 --script '
                   + shlex.quote(str(probe)) + ' "$@"\n')
wrapper.chmod(0o755)
env["GRAFFITTY_GODOT"] = str(wrapper)
os.environ["GRAFFITTY_TEST_SERVER"] = str(app / "Contents/Resources/graffitty/tools/gft")
env["GRAFFITTY_SERVER__NAVIGATOR__ENABLED"] = "true"
with PrivateServer(env, directory, "/bin/sh"):
    with (directory / "godot.log").open("w") as log:
        result = subprocess.run([
            str(app / "Contents/MacOS/Graffitty"), "--", "--shell=/bin/sh", "--workspace=main",
        ], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45)
    output = (directory / "godot.log").read_text()
    print(output)
    assert result.returncode == 0 and "RELEASE_RUNTIME=true DEBUG=false" in output
    assert "[host] world=" in output and "ERROR:" not in output
print("MACOS_RELEASE_PASS")
