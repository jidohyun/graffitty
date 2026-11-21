"""Opt-in test against a real OpenCode v2 TUI/server, using a local model fixture.

OPENCODE_TEST_BINARY=/path/to/opencode GRAFFITTY_TEST_CLI=target/debug/gft \
    python3 tests/run.py test_opencode_native.py agents
No model credentials or paid requests are used.
"""
import base64
import fcntl
import http.server
import json
import os
import pty
import signal
import struct
import subprocess
import termios
import threading
import time
import unittest
import urllib.request
from pathlib import Path

import test_opencode_integration as bridge_tests

BIN = bridge_tests.BIN


@unittest.skipUnless(os.environ.get("OPENCODE_TEST_BINARY"), "set OPENCODE_TEST_BINARY to test OpenCode v2")
class NativeOpenCode(unittest.TestCase):
    def test_home_screen_registers_ready_before_any_prompt(self):
        fixture = bridge_tests.OpenCodeIntegration()
        fixture.setUp()
        self.addCleanup(fixture.tmp.cleanup)
        self.addCleanup(fixture.stop_server)
        root = fixture.home
        binary = os.environ["OPENCODE_TEST_BINARY"]
        env = {k: v for k, v in fixture.env.items() if not k.startswith(("GRAFFITTY_", "OPENCODE_", "XDG_"))}
        env.update(OPENCODE_CONFIG_DIR=str(root / "config"), OPENCODE_TEST_HOME=str(root / "home"),
                   XDG_DATA_HOME=str(root / "data"), XDG_STATE_HOME=str(root / "state"),
                   XDG_CONFIG_HOME=str(root / "config-root"), XDG_CACHE_HOME=str(root / "cache"),
                   OPENCODE_PASSWORD="local-fixture-password", OPENCODE_DISABLE_AUTOUPDATE="true",
                   OPENCODE_DISABLE_MODELS_FETCH="true", TERM="xterm-256color")
        installed = subprocess.run([BIN, "integrate", "agent", "opencode", "--apply"], env=env, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        (root / "config/opencode.json").write_text("{}")
        server_log = (root / "server.log").open("wb")
        self.addCleanup(server_log.close)
        server = subprocess.Popen([binary, "serve", "--hostname", "127.0.0.1", "--port", "0"], env=env, cwd=root,
                                  stdout=server_log, stderr=server_log, start_new_session=True)
        self.addCleanup(self.stop, server)
        self.wait(lambda: "server listening on " in (root / "server.log").read_text(), "OpenCode server startup")
        url = (root / "server.log").read_text().split("server listening on ")[1].splitlines()[0]
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 130, 0, 0))
        tui = subprocess.Popen([binary, "--server", url], cwd=root,
                               env={**env, **{k: v for k, v in fixture.env.items() if k.startswith("GRAFFITTY_")}},
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.addCleanup(os.close, master)
        self.addCleanup(self.stop, tui)

        def drain():
            while True:
                try:
                    data = os.read(master, 65536)
                    if not data:
                        return
                    for query, answer in [(b"\x1b[6n", b"\x1b[1;1R"), (b"\x1b[c", b"\x1b[?1;2c"), (b"\x1b[>c", b"\x1b[>0;0;0c")]:
                        if query in data:
                            os.write(master, answer)
                except OSError:
                    return
        threading.Thread(target=drain, daemon=True).start()
        self.wait(lambda: fixture.lifecycle("SessionStart"), "home screen readiness without creating a session")
        start = fixture.lifecycle("SessionStart")[0]
        self.assertEqual((start["provider"], start["pid"], start["transport"]), ("opencode", tui.pid, "native"))
        self.assertTrue(start["integrated"])
        self.assertNotIn("session_id", start)
        self.assertNotIn("transcript_path", start)
        self.assertNotIn("restore", start)
        self.assertFalse(fixture.lifecycle("Stop"))

    def test_tui_queue_revocation_drafts_context_tool_and_completion(self):
        fixture = bridge_tests.OpenCodeIntegration()
        fixture.setUp()
        self.addCleanup(fixture.tmp.cleanup)
        self.addCleanup(fixture.stop_server)
        root = fixture.home
        binary = os.environ["OPENCODE_TEST_BINARY"]
        env = {k: v for k, v in fixture.env.items() if not k.startswith(("GRAFFITTY_", "OPENCODE_", "XDG_"))}
        env.update(OPENCODE_CONFIG_DIR=str(root / "config"), OPENCODE_TEST_HOME=str(root / "home"),
                   XDG_DATA_HOME=str(root / "data"), XDG_STATE_HOME=str(root / "state"),
                   XDG_CONFIG_HOME=str(root / "config-root"), XDG_CACHE_HOME=str(root / "cache"),
                   OPENCODE_PASSWORD="local-fixture-password", OPENCODE_DISABLE_AUTOUPDATE="true",
                   OPENCODE_DISABLE_MODELS_FETCH="true", TERM="xterm-256color")
        calls, entered, release = [], threading.Event(), threading.Event()
        self.addCleanup(release.set)

        class Model(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                calls.append(body)
                entered.set()
                release.wait(30)
                has_tool = any(t["function"]["name"] == "graffitty" for t in body.get("tools", []))
                used_tool = any(m["role"] == "tool" for m in body.get("messages", []))
                delta, finish = {"content": "Native OpenCode integration works."}, "stop"
                if has_tool and not used_tool:
                    delta = {"tool_calls": [{"index": 0, "id": "call_graph", "type": "function", "function": {
                        "name": "graffitty", "arguments": json.dumps({"method": "graph.send", "params": {"to": "%2", "text": "Native tool reply"}})}}]}
                    finish = "tool_calls"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for chunk, reason in [(delta, None), ({}, finish)]:
                    value = {"id": "chatcmpl-test", "object": "chat.completion.chunk", "created": int(time.time()), "model": "fixture",
                             "choices": [{"index": 0, "delta": chunk, "finish_reason": reason}]}
                    self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")

        model = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        self.addCleanup(model.server_close)
        self.addCleanup(model.shutdown)
        installed = subprocess.run([BIN, "integrate", "agent", "opencode", "--apply"], env=env, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        (root / "config/opencode.json").write_text(json.dumps({"model": "fixture/fixture", "providers": {"fixture": {
            "package": "@opencode/ai/providers/openai-compatible", "settings": {"baseURL": f"http://127.0.0.1:{model.server_port}/v1"},
            "models": {"fixture": {"capabilities": {"tools": True}, "limit": {"context": 32000, "output": 2000}}}}}}))
        server_log = (root / "server.log").open("wb")
        self.addCleanup(server_log.close)
        server = subprocess.Popen([binary, "serve", "--hostname", "127.0.0.1", "--port", "0"], env=env, cwd=root,
                                  stdout=server_log, stderr=server_log, start_new_session=True)
        self.addCleanup(self.stop, server)
        self.wait(lambda: "server listening on " in (root / "server.log").read_text(), "OpenCode server startup")
        url = (root / "server.log").read_text().split("server listening on ")[1].splitlines()[0]
        auth = "Basic " + base64.b64encode(b"opencode:local-fixture-password").decode()

        def api(path, body=None):
            request = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
                                             headers={"Authorization": auth, "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.loads(response.read() or "{}")

        sid = api("/api/session", {"title": "Graffitty native test", "location": {"directory": str(root)},
                                  "model": {"providerID": "fixture", "id": "fixture"}})["data"]["id"]
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 130, 0, 0))
        tui = subprocess.Popen([binary, "--server", url, "--session", sid, "--auto"], cwd=root,
                               env={**env, **{k: v for k, v in fixture.env.items() if k.startswith("GRAFFITTY_")}},
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.addCleanup(os.close, master)
        self.addCleanup(self.stop, tui)
        terminal = bytearray()

        def drain():
            while True:
                try:
                    data = os.read(master, 65536)
                    if not data:
                        return
                    terminal.extend(data)
                    for query, answer in [(b"\x1b[6n", b"\x1b[1;1R"), (b"\x1b[c", b"\x1b[?1;2c"), (b"\x1b[>c", b"\x1b[>0;0;0c")]:
                        if query in data:
                            os.write(master, answer)
                except OSError:
                    return
        threading.Thread(target=drain, daemon=True).start()
        self.wait(lambda: fixture.lifecycle("SessionStart"), "real TUI plugin registration")
        self.assertEqual(fixture.lifecycle("SessionStart")[0]["provider"], "opencode")
        os.write(master, b"UNSENT_DRAFT")
        event = {"event_id": "native-e2e", "source": "%2", "target": "%1", "run_id": "native-run", "text": "Check the integration", "sessions": []}
        fixture.queue = [event]
        fixture.publish()
        self.wait(entered.is_set, "native model request")
        self.wait(lambda: any(r["method"] == "graph.ack" for r in fixture.requests), "executed input acknowledgement")
        fixture.queue = [{**event, "event_id": "revoke-e2e", "text": "This queued input must be cancelled"}]
        fixture.publish()
        self.wait(lambda: api(f"/api/session/{sid}/inbox")["data"], "durable queue while model is running")
        fixture.queue = []
        fixture.publish()
        self.wait(lambda: not api(f"/api/session/{sid}/inbox")["data"], "native queue cancellation after revocation")
        release.set()
        self.wait(lambda: fixture.lifecycle("Stop"), "native turn completion")
        self.wait(lambda: any(r["method"] == "graph.send" for r in fixture.requests), "session-bound Send tool")
        self.assertTrue(any("For OpenCode use the graffitty tool" in json.dumps(call) for call in calls))
        self.assertEqual(fixture.lifecycle("Stop")[-1]["outcome"], "succeeded")
        self.assertEqual(fixture.lifecycle("Stop")[-1]["text"], "Native OpenCode integration works.")
        exported = api(f"/api/experimental/session/{sid}/export?sanitize=false")["data"]
        text = json.dumps(exported)
        self.assertNotIn("UNSENT_DRAFT", text)
        self.assertNotIn("This queued input must be cancelled", text)
        self.assertIn("Native OpenCode integration works.", text)
        start = fixture.lifecycle("SessionStart")[0]
        transcript = Path(start["transcript_path"])
        self.assertIn("Native OpenCode integration works.", transcript.read_text())
        # The real v2 plugin declares how a checkpoint reopens this conversation,
        # in the data and config locations this OpenCode process had.
        restore = start["restore"]
        self.assertEqual((Path(restore["command"][0]).name, restore["command"][1:]), ("opencode", ["--session", start["session_id"]]))
        self.assertEqual(restore["env"], {**{name: env[name] for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME",
                                                                          "XDG_CACHE_HOME", "OPENCODE_CONFIG_DIR")},
                                          "OPENCODE_CONFIG": None, "OPENCODE_DB": None})

    def wait(self, predicate, label):
        end = time.monotonic() + 35
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.1)
        self.fail(label)

    @staticmethod
    def stop(process):
        if process.poll() is not None:
            return
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
