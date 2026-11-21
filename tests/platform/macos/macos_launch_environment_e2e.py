# /// script
# dependencies = ["websocket-client"]
# ///
"""Exercise the installed launcher with Finder's cwd/PATH, then launch real Neovim."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_server import PrivateServer
from test_session_transfer import Peer

app = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="gft-finder-e2e-") as temporary:
    directory = Path(temporary)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    capture = directory / "capture.py"
    capture.write_text("import os,json,sys\nprint(json.dumps(dict(path=os.environ['PATH'], cwd=os.environ['GRAFFITTY_INITIAL_PWD'], args=sys.argv[1:])))\n")
    wrapper = directory / "runtime"
    wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(capture)) + ' "$@"\n')
    wrapper.chmod(0o755)
    env["GRAFFITTY_GODOT"] = str(wrapper)
    launcher = str(app / "Contents/MacOS/Graffitty")
    def launch(cwd, *args):
        output = subprocess.check_output([launcher, *args], env=env, cwd=cwd, text=True)
        return json.loads(output)
    finder = launch("/")
    assert finder["cwd"] == str(Path.home()), finder
    assert finder["path"].startswith(env["PATH"] + ":"), finder
    assert shutil.which("nvim", path=finder["path"]), "Neovim must be installed for this E2E"
    assert Path(launch(directory)["cwd"]).resolve() == directory.resolve()
    assert "--cwd=/" in launch("/", "--cwd", "/")["args"]
    custom = directory / "bin"
    env["PATH"] = str(custom) + ":" + env["PATH"]
    assert launch(directory)["path"].startswith(str(custom) + ":")
    env["PATH"] = finder["path"]
    os.environ["GRAFFITTY_TEST_SERVER"] = str(app / "Contents/Resources/graffitty/tools/gft")
    with PrivateServer(env, directory, "/bin/sh") as server:
        peer = Peer(json.loads(server.descriptor.read_text())["local"])
        try:
            created = peer.action("create", kind="tab", spawn={"cwd": finder["cwd"], "login": False})
            pane = created["created"]
            pwd = directory / "pwd.txt"
            peer.action("text", pane, text="pwd -P > " + shlex.quote(str(pwd)) + "\n")
            deadline = time.monotonic() + 5
            while (not pwd.exists() or not pwd.read_text().strip()) and time.monotonic() < deadline:
                time.sleep(.02)
            assert pwd.read_text().strip() == str(Path.home().resolve())
            # The packaged app's own bundled filetree runtime, found beside tools/gft.
            tree = peer.action("rpc", pane, method="filetree.toggle", params={})
            assert "error" not in tree and "pane" in tree.get("result", {}), tree
            tree_id = int(tree["result"]["pane"].lstrip("%"))
            topology = peer.sync()
            assert any(p["id"] == tree_id and p["pid"] > 0 for p in topology["panes"]), topology
        finally:
            peer.socket.close()
print("MACOS_LAUNCH_ENVIRONMENT_PASS")
