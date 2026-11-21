"""Built-in nodes report checkpoint state to a real server: what a relaunch continues from."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient

CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))


class NodeCheckpointState(unittest.TestCase):
    def test_manual_prompt_draft_and_scheduled_trigger_progress_reach_a_checkpoint(self):
        with tempfile.TemporaryDirectory(prefix="gr-node-state-") as tmp:
            root = Path(tmp).resolve()
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            env["GRAFFITTY_CHECKPOINT_DIR"] = str(root / "checkpoints")
            env["GRAFFITTY_SERVER__CHECKPOINTS__ENABLED"] = "false"

            def cli(*args):
                result = subprocess.run([CLI, *args], env=env, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout

            with PrivateServer(env, root, "/bin/sh") as owner:
                cli("session", "new", "-d", "-s", "nodes", "-c", str(root))
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "nodes")
                try:
                    prompt = client.topology["panes"][0]["id"]
                    trigger = client.action("create", prompt, kind="pane")["created"]

                    def type_in(pane, text, enter=True):
                        reply = client.action("rpc", pane, method="terminal.type", params={"text": text, "interval_ms": 0})
                        self.assertNotIn("error", reply, reply)
                        if enter:
                            self.assertNotIn("error", client.action("rpc", pane, method="terminal.press", params={"key": "Enter"}))

                    type_in(prompt, f"{shlex.quote(str(CLI))} node manual-prompt")
                    # Far in the future, so the armed trigger never fires during the test.
                    type_in(trigger, f"{shlex.quote(str(CLI))} node scheduled-trigger --every 1h"
                                     " --from 2099-01-01T00:00:00+00:00 --text Ping --headless")
                    time.sleep(1.5)
                    type_in(prompt, "unsent draft", enter=False)
                finally:
                    client.socket.close()
                deadline = time.monotonic() + 30
                while True:
                    saved = json.loads(Path(json.loads(cli("checkpoint", "save"))["path"]).read_text())
                    panes = {p["id"]: p for p in saved["windows"][0]["panes"]}
                    states = {pane: panes[pane].get("node", {}).get("state", {}) for pane in (prompt, trigger)}
                    if states[prompt].get("draft") == "unsent draft" and states[trigger].get("schedule"):
                        break
                    self.assertLess(time.monotonic(), deadline, (states, (owner.directory / "server.log").read_text()))
                    time.sleep(0.3)
                # The unsent draft and the armed schedule, in absolute times.
                self.assertEqual(states[prompt]["sent"], [])
                self.assertEqual(states[trigger]["count"], 0)
                self.assertEqual(states[trigger]["schedule"]["next"], 4070908800000)
                self.assertEqual(states[trigger]["schedule"]["every"], 3600000)
                self.assertEqual(states[trigger]["settings"]["text"], "Ping")


if __name__ == "__main__":
    unittest.main()
