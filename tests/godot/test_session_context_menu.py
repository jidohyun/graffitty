"""Session menu actions target an inactive session on owned local and remote servers."""
from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures
from test_terminal_scene import Owner


class SessionContextMenuTests(unittest.TestCase):
    def test_menu_rename_cancel_and_kill_on_local_and_remote_servers(self):
        for remote in (False, True):
            with self.subTest(remote=remote), ExitStack() as stack:
                evidence = os.environ.get("GRAFFITTY_TEST_EVIDENCE")
                if evidence:
                    directory = Path(evidence) / ("remote" if remote else "local")
                    directory.mkdir(parents=True, exist_ok=False)
                else:
                    directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="gft-menu-", dir="/tmp" if os.name != "nt" else None)))
                env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
                for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                    env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
                config = directory / "config/graffitty/client.toml"
                config.parent.mkdir(parents=True)
                config.write_text('[world]\npath="flat-2d"\n[power]\nenabled=false\n[effects]\nprofile="off"\n')
                if remote:
                    owner = stack.enter_context(Owner(network=True))
                    env["GRAFFITTY_TEST_REMOTE_DESCRIPTOR"] = str(owner.descriptor)
                else:
                    stack.enter_context(PrivateServer(env, directory, "pwsh.exe" if os.name == "nt" else "/bin/sh"))
                env["GRAFFITTY_TEST_EVIDENCE"] = str(directory)
                graphics = ["--headless"]
                if sys.platform == "darwin":
                    graphics = prepare_background(env, directory / "guard")
                    graphics.remove("--disable-render-loop")
                with (directory / "godot.log").open("w") as log:
                    result = subprocess.run([os.environ.get("GODOT", "godot"), *graphics,
                                             "--path", str(ROOT / "frontends/godot/project"),
                                             "--script", "tests/session_context_menu_smoke.gd"],
                                            env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
                output = (directory / "godot.log").read_text()
                self.assertEqual(result.returncode, 0, output)
                self.assertNotIn("ERROR:", output)
                self.assertIn("SESSION_CONTEXT_MENU_PASS", output)
                if sys.platform == "darwin":
                    self.assertFalse(background_failures(directory / "guard"))


if __name__ == "__main__":
    unittest.main()
