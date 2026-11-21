"""Server TOML defaults reach real PTYs and remain overridable per spawn."""
import contextlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from test_session_transfer import Peer


@contextlib.contextmanager
def configured_owner(env, directory):
    try:
        shell = os.environ.get("GRAFFITTY_TEST_SHELL", "pwsh.exe" if os.name == "nt" else "/bin/sh")
        with PrivateServer(env, directory, shell) as owner:
            yield owner
    except RuntimeError as error:
        log = directory / "session-owner/server.log"
        raise RuntimeError(f"{error}\n{log.read_text() if log.exists() else ''}") from error


class ServerSettingsTests(unittest.TestCase):
    def test_owner_defaults_and_explicit_spawn_override(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-settings-e2e-") as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
            env["XDG_CONFIG_HOME"] = str(directory / "config")
            env["XDG_STATE_HOME"] = str(directory / "state")
            config = directory / "config/graffitty/server.toml"
            config.parent.mkdir(parents=True)
            config.write_text(
                '[terminal]\nlogin_shell=false\n'
                '[terminal.limits]\nscrollback_bytes=12345\nkitty_image_storage_mb=7\n'
                '[nodes]\npending_per_node=3\nrun_messages=8\n'
            )
            env["GRAFFITTY_SERVER__TERMINAL__LIMITS__KITTY_IMAGE_TRANSMISSION_MIB"] = "12"
            with configured_owner(env, directory) as owner:
                descriptor = json.loads(owner.descriptor.read_text())["local"]
                peer = Peer(descriptor, "settings", new=True)
                try:
                    self.assertNotIn("localization", peer.topology)
                    pane = peer.topology["panes"][0]
                    self.assertEqual(pane["limits"], {"scrollback_bytes": 12345,
                        "kitty_image_storage_mb": 7, "kitty_image_transmission_mib": 12})
                    self.assertEqual(peer.topology["graph"]["limits"]["pending_per_node"], 3)
                    self.assertEqual(peer.topology["graph"]["limits"]["run_messages"], 8)
                    reply = peer.action("create", pane["id"], spawn={"kitty_image_storage_mb": 9})
                    self.assertNotEqual(reply["type"], "error", reply)
                    panes = peer.sync()["panes"]
                    self.assertEqual(len(panes), 2)
                    created = next(p for p in panes if p["id"] != pane["id"])
                    self.assertEqual(created["limits"]["kitty_image_storage_mb"], 9)
                    self.assertEqual(created["limits"]["kitty_image_transmission_mib"], 12)
                finally:
                    peer.socket.close()


if __name__ == "__main__":
    unittest.main()
