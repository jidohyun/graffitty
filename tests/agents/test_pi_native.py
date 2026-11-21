"""Opt-in Pi 1.3+ TUI smoke test with a local model; no real credentials.

PI_TEST_BINARY=/path/to/pi GRAFFITTY_TEST_CLI=target/release/gft \
    python3 tests/run.py test_pi_native.py agents
Uses Pi's documented controlled-tmux workflow, isolated from existing sessions.
"""
import http.server
import json
import os
import shlex
import subprocess
import threading
import time
import unittest
from pathlib import Path

import test_pi_integration as bridge_tests


@unittest.skipUnless(os.environ.get("PI_TEST_BINARY"), "set PI_TEST_BINARY to test the real Pi TUI")
class NativePi(unittest.TestCase):
    def test_tui_receive_read_send_draft_revocation_and_completion(self):
        fixture = bridge_tests.PiIntegration()
        fixture.setUp()
        self.addCleanup(fixture.tmp.cleanup)
        self.addCleanup(fixture.stop_server)
        root = fixture.home
        env = {k: v for k, v in fixture.env.items() if not k.startswith(("XDG_", "ANTHROPIC_", "OPENAI_", "GEMINI_", "GOOGLE_"))}
        env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "xdg"), TERM="xterm-256color")
        home = Path(env["PI_CODING_AGENT_DIR"])
        installed = subprocess.run([bridge_tests.BIN, "integrate", "agent", "pi", "--apply"], env=env, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)
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
                used = sum(m["role"] == "tool" for m in body.get("messages", []))
                delta, finish = {"content": "Native Pi integration works."}, "stop"
                if used < 2:
                    params = {"method": "graph.read", "params": {"node": "%2"}} if used == 0 else {
                        "method": "graph.send", "params": {"to": "%2", "text": "Native Pi tool reply"}}
                    delta = {"tool_calls": [{"index": 0, "id": f"call_graph{used}", "type": "function", "function": {
                        "name": "graffitty", "arguments": json.dumps(params)}}]}
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
        (home / "models.json").write_text(json.dumps({"providers": {"fixture": {
            "baseUrl": f"http://127.0.0.1:{model.server_port}/v1", "api": "openai-completions", "apiKey": "local-fixture",
            "models": [{"id": "fixture", "name": "Fixture", "contextWindow": 32000, "maxTokens": 2000, "reasoning": False, "input": ["text"]}]}}}))
        (home / "settings.json").write_text(json.dumps({"quietStartup": True, "defaultProvider": "fixture", "defaultModel": "fixture"}))
        socket = f"gft-pi-{os.getpid()}"

        def tmux(*args, check=True):
            result = subprocess.run(["tmux", "-L", socket, *args], env=env, capture_output=True, text=True, timeout=5)
            if check:
                self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

        self.addCleanup(lambda: tmux("kill-server", check=False))
        command = shlex.join([os.environ["PI_TEST_BINARY"], "--provider", "fixture", "--model", "fixture"])
        tmux("new-session", "-d", "-s", "test", "-c", str(root), "-x", "130", "-y", "40", command)
        capture = lambda: tmux("capture-pane", "-pt", "test", check=False)
        self.wait(lambda: fixture.lifecycle("SessionStart"), "Pi extension startup", capture)
        self.assertEqual(fixture.lifecycle("SessionStart")[0]["provider"], "pi")
        tmux("send-keys", "-t", "test", "-l", "UNSENT_DRAFT")
        event = {"event_id": "native-pi", "source": "%2", "target": "%1", "run_id": "native-run", "text": "Check the integration", "sessions": []}
        fixture.queue = [event]
        fixture.publish()
        self.wait(entered.is_set, "Pi model request", capture)
        self.wait(lambda: any(r["method"] == "graph.ack" for r in fixture.requests), "executed input acknowledgement", capture)
        fixture.queue = [{**event, "event_id": "revoked-pi", "text": "REVOKED_INPUT"}]
        fixture.publish()
        # Let busy-state and push callbacks settle, then retract before the model ends.
        time.sleep(.7)
        self.assertEqual(len(calls), 1)
        fixture.queue = []
        fixture.publish()
        release.set()
        self.wait(lambda: fixture.lifecycle("Stop"), "settled completion", capture)
        self.assertEqual(len(fixture.lifecycle("Stop")), 1)
        self.assertEqual(fixture.lifecycle("Stop")[0]["text"], "Native Pi integration works.")
        for method in ("graph.read", "graph.send"):
            self.assertTrue(any(r["method"] == method for r in fixture.requests), method)
        self.assertTrue(any("Current graph" in json.dumps(call) for call in calls))
        transcript = Path(fixture.lifecycle("SessionStart")[0]["transcript_path"])
        self.assertIn("Native Pi integration works.", transcript.read_text())
        self.assertNotIn("UNSENT_DRAFT", transcript.read_text())
        self.assertNotIn("REVOKED_INPUT", transcript.read_text())
        self.wait(lambda: "UNSENT_DRAFT" in capture(), "draft preserved in editor", capture)
        start = fixture.lifecycle("SessionStart")[0]
        pane_pid = int(tmux("display-message", "-pt", "test", "#{pane_pid}").strip())
        layout = root / "layout.json"
        layout.write_text(json.dumps({"version": 1, "windows": [{"position": [0, 0], "size": [900, 700], "active": 1,
            "tabs": [{"id": 1, "focused": "%1", "tree": {"pane": "%1"}}],
            "panes": [{"id": 1, "pid": pane_pid, "cwd": str(root), "node": {**start["restore"], "pid": start["pid"]}}],
            "chromiums": []}]}))
        saved = subprocess.run([bridge_tests.BIN, "checkpoint", "save", "--input", str(layout)],
                               env={**env, "GRAFFITTY_CHECKPOINT_DIR": str(root / "saved")}, capture_output=True, text=True, timeout=15)
        self.assertEqual(saved.returncode, 0, saved.stderr)
        checkpoint = json.loads(Path(json.loads(saved.stdout)["path"]).read_text())
        # Pi declares its own relaunch: the exact session file and its agent directory.
        node = checkpoint["windows"][0]["panes"][0]["node"]
        self.assertEqual((node["command"][1:], node["env"]),
                         (["--session", start["session_file"]], {"PI_CODING_AGENT_DIR": str(home), "PI_CODING_AGENT_SESSION_DIR": None}))
        # /new creates another runtime in the same process, ending the old binding.
        tmux("send-keys", "-t", "test", "C-u")
        tmux("send-keys", "-t", "test", "-l", "/new")
        tmux("send-keys", "-t", "test", "Enter")
        self.wait(lambda: len(fixture.lifecycle("SessionStart")) == 2, "session replacement", capture)
        self.assertEqual(len(fixture.lifecycle("SessionEnd")), 1)
        self.assertNotEqual(*[event["session_id"] for event in fixture.lifecycle("SessionStart")])
        self.assertEqual(len(fixture.lifecycle("Stop")), 1)

    def wait(self, predicate, label, capture):
        end = time.monotonic() + 20
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.1)
        self.fail(f"{label}\n{capture()}")
