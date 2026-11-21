"""In-place attachment, live menus, retained PTYs and independent clients."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient, local_socket

CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/debug/gft")))
SHELL = "pwsh.exe" if os.name == "nt" else "/bin/sh"


def shell_cli(arguments):
    quoted = str(CLI).replace("'", "''" if os.name == "nt" else "'\\''")
    return ("& " if os.name == "nt" else "") + f"'{quoted}' {arguments}\r"

def process_alive(pid):
    if os.name != "nt":
        os.kill(pid, 0)
        return True
    import ctypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
    finally:
        kernel.CloseHandle(handle)


@contextmanager
def _test_directory(prefix):
    evidence = os.environ.get("GRAFFITTY_TEST_EVIDENCE")
    if evidence:
        directory = Path(evidence)
        directory.mkdir(parents=True, exist_ok=True)
        yield tempfile.mkdtemp(prefix=prefix, dir=directory)
    else:
        with tempfile.TemporaryDirectory(prefix=prefix) as directory:
            yield directory


class SwitchingClient(PrivateClient):
    def __init__(self, local, workspace):
        self.socket = local_socket(local["url"], 10)
        self.timeout = 10
        self.frames = []
        self.sequence = 0
        self.send(dict(type="auth_local", version=1, token=local["token"],
                       workspace=workspace, features=["session-switch-v1"]))
        self.until(lambda m: m.get("type") == "ready")
        self.topology = self.until(lambda m: m.get("type") == "topology")


class SessionSwitchTests(unittest.TestCase):
    def test_switch_delivers_cached_resources_after_topology_without_waiting_for_tick(self):
        with _test_directory(prefix="gr-stats-") as tmp:
            directory = Path(tmp).resolve()
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, SHELL) as owner:
                for name in ("alpha", "beta"):
                    subprocess.run([CLI, "session", "new", "-d", "-s", name], env=env, capture_output=True, check=True)
                client = SwitchingClient(json.loads(owner.descriptor.read_text())["local"], "alpha")
                try:
                    # Observe a fresh tick before switching: waiting for the
                    # next periodic delivery would cost almost a full second.
                    client.until(lambda m: m.get("type") == "resources" and
                                 all(s["snapshot"].get("cpu_valid") for s in m["samples"]))
                    for target in ("beta", "alpha", "beta"):
                        client.send(dict(type="session_switch", name=target, request=900))
                        client.until(lambda m: m.get("type") == "session_switched")
                        started = time.monotonic()
                        packets = []
                        def collect(message):
                            packets.append(message)
                            return message.get("type") == "resources"
                        sample = client.until(collect)
                        self.assertLess(time.monotonic() - started, .6, "Cached stats waited for the periodic tick")
                        topology = next((m for m in packets if m.get("type") == "topology"), None)
                        self.assertIsNotNone(topology, "Resources arrived before the destination panes")
                        panes = {p["id"]: p for p in topology["panes"]}
                        self.assertEqual({s["session"] for s in sample["samples"]}, set(panes))
                        for entry in sample["samples"]:
                            data = entry["snapshot"]
                            self.assertEqual(data["root_pid"], panes[entry["session"]]["pid"])
                            self.assertEqual(data["status"], "running")
                            self.assertTrue(data["cpu_valid"], "Inactive session lost its CPU baseline")
                            self.assertGreater(data["memory_current"], 0)
                            self.assertLess(data["sample_age_seconds"], 2)
                            self.assertFalse(data["coverage_gap"])
                finally:
                    client.socket.close()

    def test_cli_switches_the_input_source_even_when_another_client_attached_later(self):
        with _test_directory(prefix="gr-switch-routing-") as tmp:
            directory = Path(tmp).resolve()
            env = {k:v for k,v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, SHELL) as owner:
                for name in ("alpha", "beta"):
                    subprocess.run([CLI, "session", "new", "-d", "-s", name], env=env, capture_output=True, check=True)
                local = json.loads(owner.descriptor.read_text())["local"]
                source = SwitchingClient(local, "alpha")
                observer = SwitchingClient(local, "alpha")
                try:
                    pane = source.topology["panes"][0]["id"]
                    # Execute the real CLI inside the real server-owned shell;
                    # its pane capability and socket come from the PTY env.
                    source.action("text", pane, text=shell_cli("session attach -t beta"))
                    try:
                        switched = source.until(lambda m:m.get("type") == "session_switched")
                    except AssertionError:
                        observer.send({"type":"history", "session":pane})
                        self.fail(observer.until(lambda m:m.get("type") == "history")["text"])
                    self.assertEqual(switched["workspace"], "$2")
                    self.assertEqual(source.until(lambda m:m.get("type") == "topology")["workspace"], "$2")
                    observer.send({"type":"sync", "request":800})
                    self.assertEqual(observer.until(lambda m:m.get("request") == 800)["type"], "ack")
                    self.assertEqual(observer.action("text", pane, text="Write-Output STILL_HERE\r" if os.name == "nt" else "printf 'STILL_HERE\\n'\n")["type"], "ack")
                    self.assertEqual(source.action("session_switch", name="missing")["type"], "error")
                    self.assertEqual(source.action("session_switch", name="beta")["type"], "ack")
                    self.assertEqual(source.action("session_switch", name="alpha")["type"], "ack")
                    self.assertEqual(source.action("history", pane)["type"], "ack")
                    for number, (spelling, name) in enumerate((("session new", "new-cli"), ("session new", "new-second")), start=3):
                        source.action("text", pane, text=shell_cli(f"{spelling} -s {name}"))
                        try:
                            switched = source.until(lambda m:m.get("type") == "session_switched")
                        except AssertionError:
                            observer.send({"type":"history", "session":pane})
                            self.fail(observer.until(lambda m:m.get("type") == "history")["text"])
                        self.assertEqual(switched["workspace"], f"${number}")
                        topology = source.until(lambda m:m.get("type") == "topology")
                        self.assertEqual(topology["workspace"], f"${number}")
                        self.assertEqual(next(s for s in source.available_sessions if s["id"] == f"${number}")["name"], name)
                        source.action("session_switch", name="alpha")
                        source.until(lambda m:m.get("type") == "topology" and m.get("workspace") == "$1")
                    source.action("text", pane, text=shell_cli("session new -d -s detached-cli"))
                    deadline = time.monotonic() + 5
                    while True:
                        listed = subprocess.run([CLI, "session", "list", "--json"], env=env, capture_output=True, text=True, check=True)
                        sessions = json.loads(listed.stdout)
                        if "detached-cli" in [s["name"] for s in sessions]: break
                        self.assertLess(time.monotonic(), deadline, "Detached CLI session was not created")
                        time.sleep(.03)
                    source.send({"type":"sync", "request":801})
                    self.assertEqual(source.until(lambda m:m.get("type") == "topology")["workspace"], "$1")
                    self.assertEqual(source.until(lambda m:m.get("request") == 801)["type"], "ack")
                    self.assertEqual(observer.action("text", pane, text="Write-Output ORIGINAL_ALIVE\r" if os.name == "nt" else "printf 'ORIGINAL_ALIVE\\n'\n")["type"], "ack")
                    self.assertEqual({s["name"] for s in sessions}, {"alpha", "beta", "new-cli", "new-second", "detached-cli"})
                finally:
                    source.socket.close()
                    observer.socket.close()

    def test_switching_in_desktop_and_android_presentations(self):
        for android in ((False,) if os.name == "nt" else (False, True)):
            with self.subTest(android=android), _test_directory(prefix="gr-switch-") as tmp:
                directory = Path(tmp).resolve()
                env = {k:v for k,v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
                for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                    env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
                env["GRAFFITTY_BIN"] = str(CLI)
                env["GRAFFITTY_TEST_REPORT"] = str(directory / "report.json")
                def cli(*args):
                    return subprocess.run([CLI, *args], env=env, capture_output=True, text=True, check=True, timeout=15)
                with PrivateServer(env, directory, SHELL) as owner:
                    cli("session", "new", "-d", "-s", "alpha")
                    cli("session", "new", "-d", "-s", "beta")
                    local = json.loads(owner.descriptor.read_text())["local"]
                    # Both observers support switching too. The input's actual
                    # source must win, independent of attachment order.
                    alpha = SwitchingClient(local, "alpha")
                    beta = SwitchingClient(local, "beta")
                    try:
                        if android:
                            self.assertEqual(alpha.action("remote_access", enabled=True, address="127.0.0.1:0")["type"], "ack")
                        args = [os.environ.get("GRAFFITTY_TEST_GODOT", "godot"), *( [] if os.name == "nt" else ["--headless"]), "--path", str(ROOT / "frontends/godot/project"),
                                "--script", "tests/live_session_switch_smoke.gd", "--", "--plugin=flat-2d"]
                        if android: args.append("--touch-controls")
                        with (directory / "godot.log").open("w") as log:
                            process = subprocess.run(args, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=80)
                        log = (directory / "godot.log").read_text()
                        self.assertEqual(process.returncode, 0, log)
                        self.assertNotIn("SCRIPT ERROR", log)
                        self.assertEqual(json.loads((directory / "report.json").read_text())["failures"], [], log)
                        for observer, name in ((alpha, "alpha"), (beta, "beta")):
                            observer.send({"type":"sync", "request":900})
                            topology = observer.until(lambda m:m.get("type") == "topology" and m.get("workspace") == observer.topology["workspace"])
                            self.assertEqual(topology["panes"][0]["pid"], observer.topology["panes"][0]["pid"])
                            self.assertEqual(observer.until(lambda m:m.get("request") == 900)["type"], "ack")
                            self.assertTrue(process_alive(topology["panes"][0]["pid"]))
                        self.assertEqual([s["name"] for s in json.loads(cli("session", "list", "--json").stdout)], ["alpha", "beta"])
                    finally:
                        alpha.socket.close()
                        beta.socket.close()


if __name__ == "__main__": unittest.main()
