"""A server started by hand is the one the app finds, and a taken remote port is named, not fatal."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "dist/bin/gft"


@unittest.skipUnless(os.name == "posix", "Private POSIX session fixture")
class ServerDiscoveryTests(unittest.TestCase):
    def setUp(self):
        # Short: holder sockets sit beside the descriptor.
        self.directory = tempfile.TemporaryDirectory(prefix="gfsd", dir="/tmp")
        self.root = Path(self.directory.name)
        self.servers = []
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(self.stop)

    def stop(self):
        for process in self.servers:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        for process in self.servers:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def env(self, name):
        home = self.root / name
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GRAFFITTY_", "TERMCTL_", "CODEX_", "XDG_"))}
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(home / kind.lower())
        env["SHELL"] = "/bin/sh"
        return home, env

    def remote_on(self, home, port):
        config = home / "config/graffitty/server.toml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(f'[remote]\nenabled = true\nbind_address = "127.0.0.1"\nport = {port}\n')

    def start(self, name, *args, port=None):
        home, env = self.env(name)
        if port is not None:
            self.remote_on(home, port)
        home.mkdir(parents=True, exist_ok=True)
        log = (home / "output.log").open("w+")
        self.addCleanup(log.close)
        process = subprocess.Popen([CLI, "server", *args], env=env, cwd=home, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT)
        self.servers.append(process)
        return home, env, process

    def descriptor(self, home, process, timeout=15):
        path = home / "state/graffitty/server.json"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail("server exited: " + (home / "output.log").read_text())
            if path.is_file():
                try:
                    value = json.loads(path.read_text())
                    if value.get("pid") == process.pid or value.get("local"):
                        return value
                except ValueError:
                    pass
            time.sleep(0.05)
        self.fail("no descriptor at " + str(path))

    def output(self, home, needle, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = (home / "output.log").read_text()
            if needle in text:
                return text
            time.sleep(0.05)
        self.fail(f"{needle!r} not in: " + (home / "output.log").read_text())

    def free_port(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def test_a_server_started_by_hand_uses_the_descriptor_the_app_looks_for(self):
        home, env, process = self.start("plain")
        value = self.descriptor(home, process)
        self.assertTrue(value["local"]["url"].startswith("ipc://"), value)
        self.assertFalse((home / "state/graffitty/remote.json").exists())
        # The CLI's own discovery, which the app shares, finds that same server.
        status = subprocess.run([CLI, "server", "--status"], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)["local"]["url"], value["local"]["url"])
        # A second one started the same way is refused instead of running beside it.
        second = subprocess.run([CLI, "server"], env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("Server already running for this connection file", second.stderr)

    def test_a_port_held_by_another_program_is_named_and_the_server_still_runs(self):
        with socket.socket() as holder:
            holder.bind(("127.0.0.1", 0))
            holder.listen()
            port = holder.getsockname()[1]
            home, _env, process = self.start("foreign", port=port)
            value = self.descriptor(home, process)
            self.assertIsNone(value["remote"], value)
            text = self.output(home, "Remote access is off")
            self.assertIn(f"127.0.0.1:{port} is in use by ", text)
            self.assertIn(f"(pid {os.getpid()})", text)
            self.assertNotIn("Graffitty server", text)
            self.assertIsNone(process.poll(), "the server keeps running for this computer")

    def test_a_port_held_by_another_graffitty_server_says_so(self):
        port = self.free_port()
        first_home, _env, first = self.start("first", port=port)
        self.assertEqual(self.descriptor(first_home, first)["remote"]["url"], f"ws://127.0.0.1:{port}")
        second_home, _env, second = self.start("second", port=port)
        self.assertIsNone(self.descriptor(second_home, second)["remote"])
        text = self.output(second_home, "Remote access is off")
        self.assertIn(f"127.0.0.1:{port} is in use by another Graffitty server (pid {first.pid})", text)
        self.assertIsNone(second.poll())

    def test_an_explicit_listen_address_that_is_taken_is_fatal_and_named(self):
        with socket.socket() as holder:
            holder.bind(("127.0.0.1", 0))
            holder.listen()
            port = holder.getsockname()[1]
            _home, env = self.env("listen")
            result = subprocess.run([CLI, "server", "--listen", f"127.0.0.1:{port}"], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"gft server: 127.0.0.1:{port} is in use by ", result.stderr)
            self.assertIn(f"(pid {os.getpid()})", result.stderr)


if __name__ == "__main__":
    unittest.main()
