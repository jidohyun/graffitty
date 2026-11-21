"""Real PTYs: terminal RPC and CLI work identically with no presentation owner.

The registered frontend deliberately never answers frontend_request messages.
Build gft first; all processes are private fixtures.
"""
import contextlib
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

from test_session_transfer import ROOT, Peer, PrivateServer

CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/release/gft"))


@unittest.skipUnless(os.name == "posix", "PTY byte fixture uses Unix select")
class TerminalOwnerApiTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="gr-terminal-api-")))
        writer = self.directory / "writer.py"
        writer.write_text("#!" + sys.executable + "\n" + textwrap.dedent('''
            import json, os, select, tty
            from pathlib import Path
            tty.setraw(0)
            folder = Path(__file__).parent
            pid = os.getpid()
            (folder / f"{pid}.json").write_text(json.dumps({key:os.environ[key] for key in
                ["GRAFFITTY_SOCKET", "GRAFFITTY_TOKEN", "GRAFFITTY_SURFACE_ID"]}))
            output = folder / f"{pid}.output"
            os.write(1, b"@@READY@@")
            with (folder / f"{pid}.input").open("ab", buffering=0) as received:
                while True:
                    if output.exists():
                        data = output.read_bytes()
                        output.unlink()
                        while data: data = data[os.write(1, data):]
                    if select.select([0], [], [], .005)[0]:
                        data = os.read(0, 65536)
                        if not data: break
                        received.write(data)
        '''))
        writer.chmod(0o700)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            self.env[f"XDG_{kind}_HOME"] = str(self.directory / kind.lower())
        self.owner = self.stack.enter_context(PrivateServer(self.env, self.directory, str(writer)))
        self.local = json.loads(self.owner.descriptor.read_text())["local"]
        self.peer = self.connect()
        self.pane = self.peer.topology["panes"][0]
        self.id = self.pane["id"]
        self.eventually(lambda: (self.directory / f"{self.pane['pid']}.json").exists())
        self.context = json.loads((self.directory / f"{self.pane['pid']}.json").read_text())
        self.eventually(lambda: "@@READY@@" in self.rpc("terminal.get_text")["result"]["text"])

    def connect(self, workspace="main"):
        peer = Peer(self.local, workspace)
        self.stack.callback(peer.socket.close)
        return peer

    def eventually(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.assertLess(time.monotonic(), deadline, "Fixture did not reach expected state")
            time.sleep(.01)

    def rpc(self, method, params=None, peer=None, pane=None):
        return (peer or self.peer).action("rpc", self.id if pane is None else pane, method=method, params=params or {})

    def cli(self, *args):
        flags = ["--json"] if "get-text" in args else []
        result = subprocess.run([CLI, *args, *flags], env=dict(self.env, **self.context),
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertNotIn("error", value)
        return value["result"]

    def api(self, method, params=None, token=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3)
            connection.connect(self.context["GRAFFITTY_SOCKET"].removeprefix("ipc://"))
            connection.sendall(json.dumps(dict(version=1, id="fixture", token=token or self.context["GRAFFITTY_TOKEN"],
                                              method=method, params=params or {})).encode() + b"\n")
            with connection.makefile("rb") as stream:
                return json.loads(stream.readline())

    def output(self, value):
        path = self.directory / f"{self.pane['pid']}.output"
        pending = path.with_suffix(".pending")
        pending.write_bytes(value)
        pending.replace(path)
        self.eventually(lambda: not path.exists())

    def received(self):
        path = self.directory / f"{self.pane['pid']}.input"
        return path.read_bytes() if path.exists() else b""

    def test_cli_and_rpc_ignore_frontend_presence_and_focus(self):
        self.assertIn("@@READY@@", self.cli("terminal", "get-text")["text"])
        # Another tab can be active; the token still names the original PTY.
        self.peer.action("create", self.id, kind="tab")
        for attached in (False, True, False):
            if attached:
                self.assertTrue(self.peer.action("frontend_register", generation=1)["result"]["owner"])
            else:
                self.peer.action("frontend_unregister")
            self.assertEqual(self.api("terminal.type", {"text":"한🙂", "interval_ms":0})["result"]["keys_sent"], 2)
            self.assertEqual(self.rpc("terminal.press", {"key":"Alt+b"})["result"]["keys_sent"], 1)
            self.assertIn("@@READY@@", self.api("terminal.get_text")["result"]["text"])
        self.eventually(lambda: self.received() == ("한🙂".encode() + b"\x1bb") * 3)
        self.assertEqual(self.cli("terminal", "send-key", "Ctrl+u")["keys_sent"], 1)

    def test_controller_resolves_across_sessions_without_changing_view_or_pane_scope(self):
        other = self.connect("project")
        pane = other.topology["panes"][0]
        original_workspace = self.peer.workspace
        def control(method, params):
            return self.peer.action("controller_rpc", call=dict(version=1, method=method, params=params))
        self.assertEqual(control("terminal.type", dict(target="project:1.1", text="한🙂", interval_ms=0))["result"]["keys_sent"], 2)
        target_file = self.directory / f"{pane['pid']}.input"
        self.eventually(lambda: target_file.exists() and target_file.read_bytes() == "한🙂".encode())
        self.assertEqual(self.received(), b"")
        self.assertEqual(control("terminal.press", dict(target=f"%{pane['id']}", key="Enter"))["result"]["keys_sent"], 1)
        self.eventually(lambda: target_file.read_bytes() == "한🙂".encode() + b"\r")
        self.assertEqual(self.peer.sync()["workspace"], original_workspace)
        listed = control("pane.list", {"target": "project"})["result"]["panes"]
        self.assertEqual([p["id"] for p in listed], [f"%{pane['id']}"])
        # The same address on a pane capability still cannot cross its scope.
        self.assertIn("error", self.api("terminal.type", {"target":f"%{pane['id']}", "text":"denied"}))
        self.assertIn("error", control("terminal.type", {"target":":1.1", "text":"no implicit GUI focus"}))

    def test_controller_rejects_versions_methods_and_invalid_targets_before_input(self):
        for version, method, params in [
            (2, "terminal.type", {"target":f"%{self.id}", "text":"denied"}),
            (1, "server.restart", {}),
            (1, "terminal.type", {"target":"missing:1.1", "text":"denied"}),
            (1, "terminal.type", {"target":f"%{self.id}", "text":"denied", "unknown":True}),
        ]:
            reply = self.peer.action("controller_rpc", call=dict(version=version, method=method, params=params))
            self.assertEqual(reply["type"], "error", reply)
        self.assertEqual(self.received(), b"")

    def test_input_activity_is_observational_and_not_replayed_on_reconnect(self):
        self.peer.send(dict(type="subscribe", sessions=[self.id]))
        self.peer.sync()
        self.assertEqual(self.api("terminal.type", {"text":"ab", "interval_ms":0})["result"]["keys_sent"], 2)
        event = self.peer.until(lambda m: m.get("type") == "terminal_input")
        self.assertEqual([key["unicode"] for key in event["keys"]], [ord("a"), ord("b")])
        self.eventually(lambda: self.received() == b"ab")
        viewer = self.connect()
        viewer.send(dict(type="subscribe", sessions=[self.id]))
        viewer.sync()
        self.api("terminal.press", {"key":"Backspace", "interval_ms":0})
        event = viewer.until(lambda m: m.get("type") == "terminal_input")
        self.assertEqual([key["unicode"] for key in event["keys"]], [8])

    def test_send_key_can_suppress_effects_without_changing_input(self):
        self.peer.send(dict(type="subscribe", sessions=[self.id]))
        self.peer.sync()
        self.assertEqual(self.cli("terminal", "send-key", "Ctrl+h", "--no-effects")["keys_sent"], 1)
        self.eventually(lambda: self.received() == b"\x08")
        self.assertEqual(self.cli("terminal", "send-key", "b")["keys_sent"], 1)
        event = self.peer.until(lambda m: m.get("type") == "terminal_input")
        self.assertEqual([key["unicode"] for key in event["keys"]], [ord("b")])
        self.eventually(lambda: self.received() == b"\x08b")
        response = self.api("terminal.press", {"key":"c", "effects":"false"})
        self.assertEqual(response["error"]["code"], "invalid_params")

    def test_owner_keyboard_modes_and_text_screen_are_authoritative(self):
        self.output(b"\x1b[?1h\x1b[>11u\r\nMODE_READY")
        self.eventually(lambda: "MODE_READY" in self.rpc("terminal.get_text")["result"]["text"])
        self.rpc("terminal.press", {"key":"Alt+b", "interval_ms":0})
        self.eventually(lambda: self.received() == b"\x1b[98;3u\x1b[98;3:3u")
        self.output(b"\x1b[<u\x1b[?1049h\x1b[2J\x1b[H" + "ALT 한글".encode())
        self.eventually(lambda: "ALT 한글" in self.rpc("terminal.get_text")["result"]["text"])
        text = self.api("terminal.get_text", {"scrollback":True})["result"]["text"]
        self.assertNotIn("MODE_READY", text)
        self.assertNotIn("\x1b", text)
        self.output(b"\x1b[?1049l\r\n" + b"\r\n".join(f"ROW_{i:03d}".encode() for i in range(50)))
        self.eventually(lambda: "ROW_049" in self.rpc("terminal.get_text")["result"]["text"])
        self.assertNotIn("ROW_000", self.rpc("terminal.get_text")["result"]["text"])
        self.assertIn("ROW_000", self.rpc("terminal.get_text", {"scrollback":True})["result"]["text"])

    def test_validation_scope_and_pid_targets_without_gui(self):
        sibling = self.peer.action("create", self.id, kind="pane")["created"]
        foreign = self.connect("foreign").topology["panes"][0]["id"]
        for method, params, code in [
            ("terminal.type", {"text":"partial\x01"}, "invalid_params"),
            ("terminal.press", {"key":"Hyper+x"}, "invalid_key"),
            ("terminal.type", {"text":"ab", "interval_ms":1001}, "invalid_params"),
            ("terminal.get_text", {"scrollback":1}, "invalid_params"),
            ("terminal.get_text", {"unknown":True}, "invalid_params"),
            ("terminal.get_text", {"target":f"%{sibling}"}, "forbidden"),
            ("terminal.get_text", {"target":f"%{foreign}"}, "invalid_target"),
            ("terminal.press", {"key":"a", "tab_id":sibling}, "forbidden"),
        ]:
            self.assertEqual(self.api(method, params)["error"]["code"], code)
        self.assertEqual(self.received(), b"")
        self.assertEqual(self.api("terminal.type", {"text":"a"}, token="invalid")["error"]["code"], "unauthorized")
        self.assertIn("@@READY@@", self.api("terminal.get_text", {"target":":1.1"})["result"]["text"])
        zero = self.api("terminal.get_text", {"target":":1.0"})["error"]
        self.assertEqual(zero["code"], "invalid_target")
        self.assertIn("pane numbers start at 1", zero["message"])
        pids = self.api("terminal.pid", {"details":True})["result"]["terminals"]
        self.assertEqual({p["pane"] for p in pids}, {f"%{self.id}", f"%{sibling}"})
        for row in pids:
            self.assertGreater(row["root_pid"], 0)
            self.assertIn("sample_age_seconds", row)
            for process in row["processes"]:
                self.assertEqual(set(process), {"pid", "parent_pid", "start_identity", "name", "memory_current"})
        self.assertEqual(len(self.api("terminal.pid", {"target":":1"})["result"]["terminals"]), 2)
        self.assertEqual(self.cli("pane", "pid", f"%{self.id}")["terminals"][0]["root_pid"], self.pane["pid"])

    def test_paced_input_does_not_block_owner_and_closure_completes_request(self):
        observer = self.connect()
        self.peer.sequence += 1
        request = self.peer.sequence
        self.peer.send(dict(type="rpc", session=self.id, request=request, method="terminal.type", params={"text":"abcdef", "interval_ms":200}))
        self.eventually(lambda: len(self.received()) > 0)
        started = time.monotonic()
        self.assertIn("@@READY@@", self.rpc("terminal.get_text", peer=observer)["result"]["text"])
        self.assertLess(time.monotonic() - started, .5)
        self.assertEqual(self.rpc("terminal.press", {"key":"x"}, peer=observer)["error"]["code"], "busy")
        done = self.peer.until(lambda m: m.get("request") == request)
        self.assertEqual(done["result"]["keys_sent"], 6)
        self.assertEqual(self.received(), b"abcdef")
        sibling = observer.action("create", self.id, kind="pane")["created"]
        self.peer.sequence += 1
        request = self.peer.sequence
        self.peer.send(dict(type="rpc", session=self.id, request=request, method="terminal.type", params={"text":"remaining", "interval_ms":200}))
        self.eventually(lambda: len(self.received()) > 6)
        observer.action("close", self.id)
        done = self.peer.until(lambda m: m.get("request") == request)
        self.assertEqual(done["error"]["code"], "workspace_closed")
        self.assertLess(done["error"]["keys_sent"], len("remaining"))
        self.assertEqual(self.rpc("terminal.pid", peer=observer, pane=sibling)["type"], "ack")

    @unittest.skipUnless(shutil.which("godot"), "Godot is required for frontend integration")
    def test_godot_routes_rpc_to_owner_and_only_observes_input(self):
        env = dict(self.env, GRAFFITTY_SERVER=str(self.owner.binary), GRAFFITTY_SERVER_DESCRIPTOR=str(self.owner.descriptor))
        result = subprocess.run(["godot", "--headless", "--path", ROOT / "frontends/godot/project",
                                 "--script", "res://tests/terminal_owner_api_smoke.gd"],
                                env=env, text=True, capture_output=True, timeout=45)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("SCRIPT ERROR", output)
        self.assertNotIn("FAIL ", output)
        self.eventually(lambda: self.received() == "한🙂".encode() + b"\x1bb\x08c")


if __name__ == "__main__":
    unittest.main()
