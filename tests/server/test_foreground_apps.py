"""The session owner publishes foreground app transitions, independent of agent turns."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient


@unittest.skipUnless(os.name == "posix", "Unix PTY foreground process groups")
class ForegroundApps(unittest.TestCase):
    @unittest.skipUnless(shutil.which("godot"), "Godot frontend")
    def test_real_frontend_settles_once_and_typing_reactivates_in_both_builtin_worlds(self):
        with tempfile.TemporaryDirectory(prefix="gft-foreground-ui-") as tmp:
            root = Path(tmp).resolve()
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            shutil.copy(shutil.which("sleep"), root / "nvim")
            env["GRAFFITTY_TEST_APP_COMMAND"] = shlex.quote(str(root / "nvim")) + " 3"
            env["ZDOTDIR"] = str(root)
            with PrivateServer(env, root, shutil.which("zsh") or shutil.which("bash")):
                # A replay drives the real frontend; packaged apps omit test scripts.
                launch = ["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                          "--script", "res://tests/foreground_effects.gd"]
                try:
                    result = subprocess.run(launch + ["--", "--workspace=main"], env=env,
                                            capture_output=True, text=True, timeout=40)
                except subprocess.TimeoutExpired as error:
                    output = (error.stdout or b"") + (error.stderr or b"")
                    self.fail("Frontend timed out:\n" + output.decode(errors="replace"))
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertIn("FOREGROUND_EFFECTS_REPLAY_PASS", output)
                self.assertNotIn("ERROR:", output)

    def test_owner_reports_apps_suspend_resume_restart_and_integration_identity(self):
        with tempfile.TemporaryDirectory(prefix="gft-foreground-") as tmp:
            root = Path(tmp).resolve()
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            env["ZDOTDIR"] = str(root)
            # Real executable identities without launching providers or loading user editor config.
            for name in ("nvim", "claude", "codex", "pi", "opencode", "node"):
                shutil.copy(shutil.which("sleep"), root / name)
            shell = shutil.which("zsh") or shutil.which("bash")
            with PrivateServer(env, root, shell) as owner:
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"])
                pane = client.topology["panes"][0]["id"]

                def observe(name):
                    # Foreground apps travel in `pane_update` deltas; the client
                    # folds them into its retained topology.
                    client.until(lambda m: m.get("type") in ("topology", "pane_update")
                                 and any(p["id"] == pane and p.get("app", {}).get("id") == name
                                         for p in client.topology["panes"]))
                    return next(p["app"] for p in client.topology["panes"] if p["id"] == pane)

                def text(value):
                    self.assertEqual(client.action("text", pane, text=value)["type"], "ack")

                try:
                    for name in ("nvim", "claude", "codex", "pi", "opencode"):
                        text(shlex.quote(str(root / name)) + " 60\n")
                        first = observe(name)
                        self.assertGreater(first["pid"], 0)
                        self.assertTrue(first["started"])
                        if name == "nvim":
                            text("\x1a")
                            observe(Path(shell).name)
                            text("fg\n")
                            self.assertEqual(observe(name), first, "Resume keeps process identity")
                        text("\x03")
                        observe(Path(shell).name)
                        if name == "nvim":
                            text(shlex.quote(str(root / name)) + " 60\n")
                            second = observe(name)
                            self.assertNotEqual(second["pid"], first["pid"])
                            text("\x03")
                            observe(Path(shell).name)

                    text(shlex.quote(str(root / "node")) + " 60\n")
                    runtime = observe("node")
                    reply = client.action("rpc", pane, method="agent.event",
                                          params={"event": "SessionStart", "provider": "pi",
                                                  "pid": runtime["pid"], "integrated": True,
                                                  "transport": "inbox", "session_id": "foreground-test"})
                    self.assertEqual(reply["type"], "ack", reply)
                    identified = observe("pi")
                    self.assertEqual(identified["pid"], runtime["pid"])
                    # An integration may stay alive/registered while its job is suspended.
                    text("\x1a")
                    observe(Path(shell).name)
                    text("fg\n")
                    self.assertEqual(observe("pi"), identified)
                    text("\x03")
                    observe(Path(shell).name)
                finally:
                    client.socket.close()


if __name__ == "__main__":
    unittest.main()
