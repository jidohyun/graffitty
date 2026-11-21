"""Repeated dev launches create windows behind a single remote listener."""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from headless_remote_e2e import Client
GODOT = (
    os.environ.get("GRAFFITTY_TEST_GODOT")
    or shutil.which("godot")
    or "/Applications/Godot.app/Contents/MacOS/Godot"
)


@unittest.skipUnless(
    sys.platform != "win32" and Path(GODOT).is_file(),
    "Unix dev launcher and Godot required",
)
class DevInstanceTests(unittest.TestCase):
    def test_new_windows_share_listener_and_restart_releases_lock(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-dev-") as directory:
            root = Path(directory)
            env = {
                k: v
                for k, v in os.environ.items()
                if not k.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL"))
            }
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            env["GRAFFITTY_INITIAL_PWD"] = str(root.resolve())
            config = root / "config/graffitty"
            config.mkdir(parents=True)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            (config / "server.toml").write_text(
                f'[remote]\nenabled = true\nbind_address = "127.0.0.1"\nport = {port}\n'
            )
            graphics = (
                [] if os.environ.get("GRAFFITTY_TEST_GRAPHICS") else ["--headless"]
            )
            command = [
                sys.executable,
                str(ROOT / "tools/dev_instance.py"),
                GODOT,
                *graphics,
                "--path",
                str(ROOT / "frontends/godot/project"),
                "res://scenes/terminal.tscn",
                "--",
                "--reload",
            ]
            descriptor = root / "state/graffitty/remote.json"
            activation = root / "state/graffitty/dev-instance.json"
            log = root / "test.log"
            client = None
            with PrivateServer(env, root, "/bin/sh") as owner, log.open("w") as output:
                descriptor = owner.descriptor
                first = subprocess.Popen(
                    command,
                    cwd=ROOT,
                    env=env,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 25
                    while not descriptor.exists() or not activation.exists():
                        self.assertIsNone(first.poll(), log.read_text())
                        self.assertLess(time.monotonic(), deadline, log.read_text())
                        time.sleep(0.05)
                    original = json.loads(descriptor.read_text())["remote"]
                    def sessions():
                        result = subprocess.run([ROOT / "target/release/gft", "session", "list", "--json"], env=env, capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        return json.loads(result.stdout)
                    initial_sessions = sessions()
                    self.assertEqual(len(initial_sessions), 1)
                    # The connection file holds the listener URL and the local capability.
                    client = Client(json.loads(descriptor.read_text()), initial_sessions[0]["id"])
                    initial_pane = client.topology["panes"][0]["id"]
                    # Concurrent launch requests must serialize through the app,
                    # creating windows while retaining the same listener/token.
                    launch_directories = [root / f"launch-{n}" for n in range(2)]
                    for path in launch_directories: path.mkdir()
                    launches = [
                        subprocess.Popen(
                            command,
                            cwd=ROOT,
                            env=dict(env, GRAFFITTY_INITIAL_PWD=str(path.resolve())),
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            text=True,
                        )
                        for path in launch_directories
                    ]
                    for launch in launches:
                        stdout, stderr = launch.communicate(timeout=20)
                        self.assertEqual(
                            launch.returncode, 0, stdout + stderr + log.read_text()
                        )
                    deadline = time.monotonic() + 15
                    while len(sessions()) != 3:
                        self.assertLess(time.monotonic(), deadline, log.read_text())
                        time.sleep(.05)
                    self.assertTrue(all(s["panes"] == 1 for s in sessions()))
                    self.assertEqual(json.loads(descriptor.read_text())["remote"], original)
                    data = json.loads(activation.read_text())
                    with socket.socket(socket.AF_UNIX) as local:
                        local.settimeout(5)
                        local.connect(data["socket"])
                        local.sendall(
                            json.dumps(
                                {"version": 1, "token": data["token"], "method": "session.capture", "params": {"layout": True}}
                            ).encode()
                            + b"\n"
                        )
                        with local.makefile("rb") as response:
                            capture = json.loads(response.readline())
                    # The API acknowledges the launch before the owner reply has
                    # installed its host; wait until every fresh window is ready.
                    deadline = time.monotonic() + 10
                    while len(capture.get("result", {}).get("windows", [])) < 3:
                        self.assertLess(time.monotonic(), deadline, log.read_text())
                        time.sleep(.05)
                        with socket.socket(socket.AF_UNIX) as local:
                            local.settimeout(5); local.connect(data["socket"])
                            local.sendall(json.dumps({"version": 1, "token": data["token"], "method": "session.capture", "params": {"layout": True}}).encode()+b"\n")
                            capture = json.loads(local.makefile("rb").readline())
                    self.assertEqual(len(capture["result"]["windows"]), 3)
                    self.assertTrue(all(len(w["panes"]) == 1 for w in capture["result"]["windows"]))
                    # Shell integration is disabled in this fixture, so OSC 7
                    # can be empty. Verify the real shell process directories.
                    actual_directories = set()
                    for window in capture["result"]["windows"]:
                        pid = window["panes"][0]["pid"]
                        if sys.platform == "darwin":
                            lines = subprocess.check_output(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], text=True).splitlines()
                            cwd = next(line[1:] for line in lines if line.startswith("n"))
                        else:
                            cwd = os.readlink(f"/proc/{pid}/cwd")
                        actual_directories.add(Path(cwd).resolve())
                    self.assertEqual(actual_directories, {root.resolve(), *(path.resolve() for path in launch_directories)})
                    self.assertEqual(client.topology["panes"][0]["id"], initial_pane)
                    self.assertEqual(activation.stat().st_mode & 0o777, 0o600)
                    for pane in client.topology["panes"]:
                        pane_id = int(pane["id"])
                        marker = f"REMOTE_WINDOW_{pane_id}_OK"
                        client.text(
                            pane_id, f"printf 'REMOTE_WINDOW_%s_OK\\n' {pane_id}\r"
                        )
                        deadline = time.monotonic() + 10
                        history = client.history(pane_id)
                        while marker not in history:
                            self.assertLess(
                                time.monotonic(),
                                deadline,
                                f"No remote output from {pane_id}: {history!r}",
                            )
                            time.sleep(0.05)
                            history = client.history(pane_id)
                    client.ws.close()
                    client = None
                    # Attaching to an already presented session focuses it;
                    # it must not create another pane or native window.
                    attached = subprocess.run(command + ["--workspace=" + initial_sessions[0]["id"], "--attach-session"],
                                              cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)
                    self.assertEqual(attached.returncode, 0, attached.stderr + log.read_text())
                    self.assertEqual(len(sessions()), 3)
                    self.assertTrue(all(s["panes"] == 1 for s in sessions()))
                    killed = subprocess.run([ROOT / "target/release/gft", "session", "kill", "-t", initial_sessions[0]["id"]],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(killed.returncode, 0, killed.stderr)
                    # Killing the root window's session promotes a surviving
                    # window; the app, listener and other shells remain alive.
                    deadline = time.monotonic() + 10
                    while True:
                        with socket.socket(socket.AF_UNIX) as local:
                            local.settimeout(5); local.connect(data["socket"])
                            local.sendall(json.dumps({"version": 1, "token": data["token"], "method": "session.capture", "params": {"layout": True}}).encode()+b"\n")
                            capture = json.loads(local.makefile("rb").readline())
                        if len(capture.get("result", {}).get("windows", [])) == 2: break
                        self.assertLess(time.monotonic(), deadline, log.read_text())
                        time.sleep(.05)
                    self.assertEqual(len(sessions()), 2)
                    self.assertIsNone(first.poll())
                    first.send_signal(signal.SIGINT)
                    first.wait(timeout=10)
                    self.assertFalse(activation.exists())
                    # The lock file may remain, but the OS lock must be released.
                    restarted = subprocess.run(
                        [
                            sys.executable,
                            str(ROOT / "tools/dev_instance.py"),
                            sys.executable,
                            "-c",
                            "pass",
                        ],
                        cwd=ROOT,
                        env=env,
                        capture_output=True,
                        check=False,
                        text=True,
                        timeout=10,
                    )
                    self.assertEqual(restarted.returncode, 0, restarted.stderr)
                    self.assertNotIn("ERROR:", log.read_text())
                finally:
                    if client is not None:
                        client.ws.close()
                    if first.poll() is None:
                        os.killpg(first.pid, signal.SIGKILL)
                        first.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
