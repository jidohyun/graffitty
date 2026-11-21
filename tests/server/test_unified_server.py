"""A single copied gft executable provides both client and server entry points."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "dist/bin/gft"


@unittest.skipUnless(os.name == "posix", "Private POSIX session fixture")
class UnifiedServerTests(unittest.TestCase):
    def test_standalone_executable_and_automatic_server_launch(self):
        # Short, with a space: holder sockets sit beside the descriptor, and a
        # Unix socket path is limited to about 104 bytes.
        with tempfile.TemporaryDirectory(prefix="gft one ", dir="/tmp") as directory:
            root = Path(directory)
            binary = root / "gft"
            shutil.copy2(CLI, binary)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GRAFFITTY_", "TERMCTL_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            env["SHELL"] = "/bin/sh"
            descriptor = root / "owner.json"
            env["GRAFFITTY_SERVER_DESCRIPTOR"] = str(descriptor)

            def run(*args, ok=True):
                result = subprocess.run([binary, *args], env=env, cwd=root,
                                        capture_output=True, text=True, timeout=25)
                if ok:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                return result

            for args in [("server", "--help"), ("help", "server")]:
                self.assertIn("--connection", run(*args).stdout)
            self.assertIn("server", run("__complete_word__", "--shell", "zsh", "--line", "gft ").stdout)
            self.assertIn("--connection", run("__complete_word__", "--shell", "zsh", "--line", "gft server --con").stdout)
            self.assertIn("protocol=", run("server", "--version").stdout)
            run("server", "--unknown", ok=False)
            run("server", "--listen", ok=False)
            self.assertFalse(descriptor.exists(), "Help and invalid arguments must not start a server")

            # The explicit server route runs in this executable's process.
            with (root / "explicit.log").open("wb") as log:
                server = subprocess.Popen([binary, "server", "--connection", descriptor,
                                           "--auth-file", root / "auth.json", "--shell", "/bin/sh"],
                                          env=env, cwd=root, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 15
                    while not descriptor.exists():
                        self.assertIsNone(server.poll(), (root / "explicit.log").read_text())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.02)
                    status = json.loads(run("server", "--connection", str(descriptor), "--status").stdout)
                    self.assertEqual(status["pid"], server.pid)
                    run("session", "new", "-d", "-s", "explicit")
                    self.assertEqual(json.loads(run("session", "list", "--json").stdout)[0]["name"], "explicit")
                    run("session", "kill", "-t", "explicit")
                    self.assertEqual(server.wait(timeout=10), 0)
                finally:
                    if server.poll() is None:
                        server.terminate()
                        server.wait(timeout=5)

            # With no owner, the CLI must start itself with the server subcommand.
            try:
                run("session", "new", "-d", "-s", "automatic")
                run("session", "has", "-t", "automatic")
                status = json.loads(run("server", "--connection", str(descriptor), "--status").stdout)
                self.assertNotEqual(status["pid"], server.pid)
                self.assertFalse((root / "gft-server").exists())
            finally:
                # This descriptor belongs exclusively to this test. Stop even
                # an owner that started successfully before session creation failed.
                status = subprocess.run([binary, "server", "--connection", descriptor, "--status"],
                                        env=env, capture_output=True, text=True, timeout=5)
                if status.returncode == 0:
                    try:
                        os.kill(json.loads(status.stdout)["pid"], signal.SIGTERM)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
