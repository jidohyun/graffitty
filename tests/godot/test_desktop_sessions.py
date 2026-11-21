"""Ordinary desktop startup and Sessions switching across owned local/remote servers."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures
from test_terminal_scene import Owner


class DesktopSessionsTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("godot"), "Godot is unavailable")
    def test_remote_launch_keeps_local_first_and_all_computers_connected(self):
        with tempfile.TemporaryDirectory(prefix="gft-desktop-", dir="/tmp" if os.name != "nt" else None) as temporary, ExitStack() as stack:
            directory = Path(temporary)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            config = directory / "config/graffitty/client.toml"
            config.parent.mkdir(parents=True)
            config.write_text('[world]\npath="flat-2d"\n[power]\nenabled=false\n[effects]\nprofile="off"\n')
            stack.enter_context(PrivateServer(env, directory, "/bin/sh"))
            connections = []
            for _ in range(2):
                remote = stack.enter_context(Owner(network=True))
                descriptor = json.loads(remote.descriptor.read_text())
                connections.append({"url": descriptor["url"], "token": descriptor["token"], "workspace": "main", "transient": True})
            launch = directory / "launch.json"
            launch.write_text(json.dumps({"connections": connections}))
            launch.chmod(0o600)
            graphics = ["--headless"]
            if sys.platform == "darwin":
                graphics = prepare_background(env, directory / "guard")
                graphics.remove("--disable-render-loop")
            result = subprocess.run([os.environ.get("GODOT", "godot"), *graphics,
                                     "--path", str(ROOT / "frontends/godot/project"),
                                     "--script", "tests/desktop_sessions_smoke.gd", "--",
                                     f"--remote-connections={launch}"],
                                    env=env, capture_output=True, text=True, timeout=100)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("ERROR:", output)
            self.assertIn("DESKTOP_SESSIONS_PASS", output)
            if os.name != "nt":
                line = next(line for line in output.splitlines() if line.startswith("DESKTOP_SHELL_PIDS "))
                for pid in json.loads(line.removeprefix("DESKTOP_SHELL_PIDS ")):
                    os.kill(int(pid), 0)
            if sys.platform == "darwin":
                self.assertFalse(background_failures(directory / "guard"))


if __name__ == "__main__":
    unittest.main()
