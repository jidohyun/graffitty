# /// script
# requires-python = ">=3.11"
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Real private-server subscriptions and typing guard; never uses the user's owner."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import sys
import subprocess
import tempfile
import time
import unittest
import uuid
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server",)]
from test_session_transfer import Peer
BIN = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))


class Lines:
    def __init__(self, path):
        if isinstance(path, tuple):
            self.socket = socket.create_connection(path, timeout=5)
        else:
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.connect(path)
        self.buffer = b""

    def send(self, value):
        self.socket.sendall(json.dumps(value).encode() + b"\n")

    def read(self, timeout=5):
        end = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            if not select.select([self.socket], [], [], max(0, end - time.monotonic()))[0]:
                return None
            data = self.socket.recv(65536)
            if not data:
                raise EOFError("subscription closed")
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def close(self):
        self.socket.close()


@unittest.skipUnless(os.name == "posix", "Unix owner/holder fixture")
class AgentWatch(unittest.TestCase):
    def test_authentication_notifications_idle_restart_and_revocation(self):
        with tempfile.TemporaryDirectory(prefix="gft-watch-", dir="/tmp") as directory:
            root = Path(directory)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "TERMCTL_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            config = root / "config/graffitty/server.toml"
            config.parent.mkdir(parents=True)
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                port = reserved.getsockname()[1]
            config.write_text(f'[remote]\nenabled=true\nbind_address="127.0.0.1"\nport={port}\n')
            descriptor = root / "owner.json"
            env.update(GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor), SHELL="/bin/sh")
            streams = []
            viewers = []

            def run(*args):
                p = subprocess.run([BIN, *args], env=env, cwd=root, capture_output=True, text=True, timeout=25)
                self.assertEqual(p.returncode, 0, p.stderr)
                return p.stdout

            def state():
                return json.loads(descriptor.with_suffix(".owner.json").read_text())

            def request(method, token, params=None):
                return dict(id=uuid.uuid4().hex, version=1, method=method, token=token, params=params or {})

            def rpc(path, token, method, params=None):
                conn = Lines(path)
                try:
                    conn.send(request(method, token, params))
                    result = conn.read()
                    self.assertNotIn("error", result, result)
                    return result["result"]
                finally:
                    conn.close()

            def watch(path, token):
                conn = Lines(path)
                streams.append(conn)
                req = request("graph.watch", token)
                conn.send(req)
                reply = conn.read()
                self.assertEqual(reply["id"], req["id"])
                return conn, reply

            try:
                workspace = run("session", "new", "-d", "-s", "watch").strip()
                saved = state()
                pane = saved["sessions"][0]
                path = str(Path(saved["runtime"]) / "session.sock")
                token = pane["token"]
                denied, reply = watch(path, "invalid-test-capability")
                self.assertIn("error", reply)
                denied.close()
                sub, reply = watch(path, token)
                self.assertTrue(reply["result"]["watching"])
                url = urlparse(json.loads(descriptor.read_text())["remote"]["url"])
                tcp_sub, tcp_reply = watch(("127.0.0.1", url.port), token)
                self.assertTrue(tcp_reply["result"]["watching"])
                self.assertIsNone(sub.read(.3), "idle must not send invalidations")
                rpc(path, token, "agent.event", dict(provider="pi", event="SessionStart", session_id="watch-fixture", transport="inbox", integrated=True))
                self.assertEqual(sub.read()["method"], "graph.changed")
                self.assertEqual(tcp_sub.read()["method"], "graph.changed")
                rpc(path, token, "agent.heartbeat")
                self.assertIsNone(sub.read(.3), "heartbeats must not wake the inbox")
                # Real viewer input, not agent RPC input, resets the per-pane
                # three-second quiet window. Delayed delivery stays revocable.
                viewer = Peer(json.loads(descriptor.read_text())["local"], workspace)
                viewers.append(viewer)
                sender = viewer.action("create", pane["id"], kind="pane")["created"]
                sender_token = next(s["token"] for s in state()["sessions"] if s["id"] == sender)
                rpc(path, sender_token, "agent.event", dict(provider="pi", event="SessionStart", session_id="sender", transport="inbox", integrated=True))
                edge = {"from": f"%{sender}", "to": f"%{pane['id']}", "send": True}
                rpc(path, sender_token, "graph.connect", edge)
                rpc(path, sender_token, "graph.send", {"to": edge["to"], "text": "wait for typing"})
                event_id = rpc(path, token, "graph.take")["events"][0]["event_id"]
                ready = lambda: rpc(path, token, "agent.delivery", {"event_id": event_id})["ready"]
                self.assertTrue(ready())
                viewer.action("text", pane["id"], text="x")
                self.assertFalse(ready())
                time.sleep(1.6)
                second_viewer = Peer(json.loads(descriptor.read_text())["local"], workspace)
                viewers.append(second_viewer)
                second_viewer.action("text", pane["id"], text="y")
                quiet_sub, reply = watch(path, token)
                self.assertTrue(reply["result"]["watching"])
                time.sleep(1.6)
                self.assertFalse(ready(), "the latest input, not the first, sets the deadline")
                # Agent-generated keys do not reset human quiet time.
                rpc(path, token, "terminal.press", {"key": "ArrowLeft", "interval_ms": 0})
                self.assertEqual(quiet_sub.read(2)["method"], "graph.changed", "quiet expiry must wake a push-only adapter")
                self.assertTrue(ready())
                viewer.action("text", pane["id"], text="z")
                self.assertFalse(ready())
                rpc(path, sender_token, "graph.disconnect", edge)
                time.sleep(3.1)
                self.assertFalse(ready(), "quiet expiry must not revive a revoked message")
                self.assertEqual(rpc(path, token, "graph.take")["events"], [])
                for viewer in viewers:
                    viewer.socket.close()
                # Drain prior graph changes before the restart checks.
                while sub.read(.05) is not None:
                    pass
                # Auth/version checks also apply to subscriptions.
                bad = Lines(path)
                streams.append(bad)
                req = request("graph.watch", token)
                req["version"] = 999
                bad.send(req)
                self.assertIn("error", bad.read())
                run("checkpoint", "save")
                run("server", "restart")
                with self.assertRaises(EOFError):
                    while sub.read() is not None:
                        pass
                restored = state()
                self.assertEqual(restored["runtime"], saved["runtime"])
                self.assertEqual(restored["sessions"][0]["token"], token)
                sub, reply = watch(path, token)
                self.assertTrue(reply["result"]["watching"])
                self.assertIsInstance(rpc(path, token, "graph.take")["events"], list)
                rpc(path, token, "agent.event", dict(provider="pi", event="SessionStart", session_id="watch-fixture", transport="inbox", integrated=True))
                self.assertEqual(sub.read()["method"], "graph.changed")
                # Keep another workspace alive: closing the subscribed pane must
                # revoke the stream, not merely rely on the server exiting.
                run("session", "new", "-d", "-s", "other")
                self.assertIsNone(sub.read(.3), "other workspaces must not invalidate this stream")
                run("session", "kill", "-t", "watch")
                with self.assertRaises(EOFError):
                    while sub.read() is not None:
                        pass
                run("session", "kill", "-t", "other")
            finally:
                for viewer in viewers:
                    viewer.socket.close()
                for conn in streams:
                    conn.close()
                p = subprocess.run([BIN, "server", "--connection", descriptor, "--status"], env=env,
                                   capture_output=True, text=True, timeout=5)
                if p.returncode == 0:
                    try:
                        os.kill(json.loads(p.stdout)["pid"], signal.SIGTERM)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
