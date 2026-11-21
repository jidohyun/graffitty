# /// script
# requires-python = ">=3.11"
# dependencies = ["pyte>=0.8,<1"]
# ///
"""Real SystemOne CLI + Godot graph + Ratatui PTY; only Decisions HTTP is mocked.
Build: cargo build --manifest-path apps/cli/Cargo.toml
Run: uv run tests/graph/test_systemone_node.py
"""
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import pty
import select
import shlex
import shutil
import struct
import termios
import threading
import time
import unittest
import pyte
import test_filter_node
from test_parallel_node import ROOT, wait, stop

CLI = os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "target/debug/gft"))


class SystemoneIntegration(unittest.TestCase):
    start = test_filter_node.FilterIntegration.start
    call = test_filter_node.FilterIntegration.call
    inbox = test_filter_node.FilterIntegration.inbox

    def setUp(self):
        test_filter_node.FilterIntegration.setUp(self)
        (self.folder / "defaults.json").write_text("{}")
        self.requests = []
        self.authorizations = []
        self.answer = {"type": "noul", "noul": 0.9}
        self.http_status = 200
        self.delay = 0
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                test.requests.append(body)
                test.authorizations.append(self.headers.get("Authorization"))
                time.sleep(test.delay)
                self.send_response(test.http_status)
                self.end_headers()
                response = {"answers": {"route": test.answer}} if test.http_status == 200 else {
                    "error": {"message": "Provider rejected test-secret", "metadata": {"secret": "test-secret"}}}
                self.wfile.write(json.dumps(response).encode())

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint_url = f"http://127.0.0.1:{self.server.server_port}/decisions"

    def tearDown(self):
        test_filter_node.FilterIntegration.tearDown(self)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def node(self, *args, env=None, **kwargs):
        return self.start([CLI, "node", "systemone", "--endpoint", self.endpoint_url, *args],
                          {**self.env, "OPENROUTER_API_KEY": "test-secret", "GRAFFITTY_NODE_CONFIG": str(self.folder / "defaults.json"), "TERM": "xterm-256color", **(env or {})}, **kwargs)

    def manifest(self):
        return next((n.get("manifest") for n in self.call(1,"graph.list")["nodes"] if n["node"] == "%3" and n.get("manifest",{}).get("name") == "SystemOne"), None)

    def connect(self, yes="True", no="False"):
        self.call(1,"graph.connect", **{"from":"%1","from_port":"result","to":"%3","to_port":"evaluate"})
        for port, target in [(yes,4),(no,2)]:
            self.call(3,"graph.connect", **{"from":"%3","from_port":port,"to":f"%{target}","to_port":"in"})

    def run_mode(self, mode, answer, expected):
        self.answer = answer
        node = self.node("--headless", "--question", "Approved?", "--mode", mode, "--once")
        wait(self.manifest)
        self.connect()
        payload = {"text": "hello", "custom": [1, None, "한글"]}
        self.call(1, "graph.emit", output="result", payload=payload)
        node.wait(timeout=10)
        self.assertEqual(node.returncode, 0)
        event = self.inbox(expected)[0]
        self.assertEqual(event["payload"], payload)
        self.assertEqual(event["text"], "hello")
        self.assertEqual(self.inbox(3), [])
        self.assertEqual(self.requests[0]["questions"]["route"]["type"], mode)
        self.assertEqual(self.requests[0]["model"], "~typesafe/jev-latest")
        self.assertEqual(self.requests[0]["state"]["payload"], payload)

    def test_noul(self): self.run_mode("noul", {"type":"noul","noul":0.9}, 4)
    def test_choice(self): self.run_mode("choice", {"type":"choice","choice":"False"}, 2)
    def test_score(self): self.run_mode("score", {"type":"score","score":0.6}, 2)

    def test_dev_mock_routes_three_choices_without_http_or_credentials(self):
        scenario = self.folder / "decisions.json"
        prompts = [("What is HTTP 429?", "sonnet", 4),
                   ("Implement a retry helper", "opus", 2),
                   ("Review this retry loop", "astra", 5)]
        scenario.write_text(json.dumps({"delay_ms": 0, "decisions": [
            {"prompt": text, "answer": {"type": "choice", "choice": port}}
            for text, port, _ in prompts]}))
        self.call(5, "agent.event", provider="adapter", event="SessionStart", session_id="reviewer")
        self.call(5, "agent.register", name="Astra", inputs=[{"id": "in"}], outputs=[])
        # The mock must work even on a machine without helper installed.
        helper = self.folder / "helper"
        helper.write_text('#!/bin/sh\necho called >> "$SECRET_TEST_LOG"\nexit 99\n')
        helper.chmod(0o700)
        env = {"PATH": str(self.folder), "OPENROUTER_API_KEY": "",
               "GRAFFITTY_SECRETS_CONFIG": str(self.folder), "SECRET_TEST_LOG": str(self.folder / "helper-calls")}
        node = self.start([CLI, "dev", "systemone-mock", "--headless", "--scenario", str(scenario),
            "--question", "Choose an agent", "--mode", "choice", "--endpoint", self.endpoint_url,
            "--credential", "must-not-be-read", "--outputs", json.dumps([
                {"id": port, "description": port} for _, port, _ in prompts])],
            {**self.env, **env, "GRAFFITTY_NODE_CONFIG": str(self.folder / "defaults.json")})
        wait(self.manifest)
        self.call(1, "graph.connect", **{"from": "%1", "from_port": "result", "to": "%3", "to_port": "evaluate"})
        for _, port, target in prompts:
            self.call(3, "graph.connect", **{"from": "%3", "from_port": port, "to": f"%{target}", "to_port": "in"})
        for text, _, target in prompts:
            payload = {"text": text, "original": ["한글", 42]}
            self.call(1, "graph.emit", output="result", payload=payload)
            event = wait(lambda: self.inbox(target))[0]
            self.assertEqual(event["payload"], payload)
            self.assertEqual(event["text"], text)
            self.call(target, "graph.ack", event_id=event["event_id"], status="delivered")
            wait(lambda: not self.inbox(3))
            self.assertTrue(all(not self.inbox(t) for _, _, t in prompts))
        self.assertEqual(self.requests, [])
        self.assertFalse((self.folder / "helper-calls").exists())
        stop(node)
        self.assertEqual(node.returncode, 0)

    def test_dev_mock_bad_choice_retains_input(self):
        scenario = self.folder / "bad-decision.json"
        scenario.write_text(json.dumps({"delay_ms": 0, "decisions": [
            {"answer": {"type": "choice", "choice": "missing"}}]}))
        node = self.start([CLI, "dev", "systemone-mock", "--headless", "--once",
            "--scenario", str(scenario), "--question", "Choose", "--mode", "choice"],
            {**self.env, "OPENROUTER_API_KEY": "", "GRAFFITTY_NODE_CONFIG": str(self.folder / "defaults.json")})
        wait(self.manifest)
        self.connect()
        self.call(1, "graph.emit", output="result", payload={"text": "hello"})
        node.wait(timeout=10)
        self.assertNotEqual(node.returncode, 0)
        self.assertEqual(self.inbox(3)[0]["progress"]["status"], "failed")
        self.assertEqual(self.inbox(4), [])
        self.assertEqual(self.inbox(2), [])
        self.assertEqual(self.requests, [])

    def secret_fixture(self, value="test-command-secret"):
        binary = self.folder / "credential-helper"
        binary.write_text('#!/bin/sh\necho called >> "$SECRET_TEST_LOG"\nprintf "%s\\n" "$TEST_SECRET_VALUE"\n')
        binary.chmod(0o700)
        config = self.folder / "secrets.toml"
        config.write_text('[defaults]\nOPENROUTER_API_KEY="work"\n[secrets.work]\ncommand=' + json.dumps([str(binary)]) + '\n')
        return {"GRAFFITTY_SECRETS_CONFIG": str(config), "SECRET_TEST_LOG":str(self.folder / "secret-calls"), "TEST_SECRET_VALUE":value, "OPENROUTER_API_KEY":""}

    def test_command_supplies_credential_once(self):
        env = self.secret_fixture()
        node = self.node("--headless", "--question", "Approved?", "--once", env=env)
        wait(self.manifest)
        self.connect()
        self.call(1,"graph.emit",output="result",payload={"text":"hello"})
        node.wait(timeout=10)
        self.assertEqual(node.returncode,0)
        self.assertEqual(self.authorizations,["Bearer test-command-secret"])
        self.assertEqual((self.folder / "secret-calls").read_text(), "called\n")
        self.assertNotIn("test-command-secret", "".join(p.read_text() for p in self.folder.glob("*.log")))

    def test_explicit_credential_overrides_environment(self):
        env = self.secret_fixture("selected-secret")
        env["OPENROUTER_API_KEY"] = "wrong-environment-secret"
        node = self.node("--headless", "--question", "Approved?", "--once", "--credential", "work", env=env)
        wait(self.manifest)
        self.connect()
        self.call(1,"graph.emit",output="result",payload={"text":"hello"})
        node.wait(timeout=10)
        self.assertEqual(node.returncode, 0)
        self.assertEqual(self.authorizations, ["Bearer selected-secret"])
        self.assertTrue((self.folder / "secret-calls").exists())

    def test_environment_and_help_skip_helpers(self):
        env = self.secret_fixture()
        (self.folder / "secrets.toml").write_text('invalid = [')
        help_process = self.start([CLI,"node","systemone","--help"],env)
        help_process.wait(timeout=5)
        self.assertEqual(help_process.returncode,0)
        env["OPENROUTER_API_KEY"] = "environment-secret"
        node = self.node("--headless", "--question", "Approved?", "--once", env=env)
        wait(self.manifest)
        self.connect()
        self.call(1,"graph.emit",output="result",payload={"text":"hello"})
        node.wait(timeout=10)
        self.assertEqual(node.returncode,0)
        self.assertEqual(self.authorizations,["Bearer environment-secret"])
        self.assertFalse((self.folder / "secret-calls").exists())

    def test_helper_failure_is_fast_and_silent(self):
        env = self.secret_fixture()
        (self.folder / "credential-helper").write_text('#!/bin/sh\necho private-error >&2\necho partial-secret\nexit 1\n')
        node = self.node("--headless", "--question", "Approved?", env=env)
        node.wait(timeout=3)
        self.assertNotEqual(node.returncode,0)
        output = "".join(p.read_text() for p in self.folder.glob("*.log"))
        self.assertIn('Credential "work"',output)
        self.assertNotIn("private-error",output)
        self.assertNotIn("partial-secret",output)

    def test_failure_retains_input(self):
        self.http_status = 401
        node = self.node("--headless", "--question", "Approved?")
        wait(self.manifest)
        self.connect()
        self.call(1,"graph.emit",output="result",payload={"text":"hello"})
        node.wait(timeout=10)
        self.assertNotEqual(node.returncode,0)
        self.assertEqual(self.inbox(3)[0]["progress"]["status"],"failed")
        self.assertEqual(self.inbox(4),[])
        self.assertEqual(self.inbox(2),[])
        logs = "".join(p.read_text() for p in self.folder.glob("*.log"))
        self.assertIn("Decision HTTP 401: Provider rejected [redacted]", logs)
        self.assertNotIn("test-secret", logs)

    def test_setup_edit_ports_save_and_live_log(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH",32,110,0,0))
        before = termios.tcgetattr(slave)
        screen = pyte.Screen(110,32)
        stream = pyte.ByteStream(screen)
        captured = bytearray()
        def drain():
            while select.select([master],[],[],0)[0]:
                chunk = os.read(master,65536)
                captured.extend(chunk)
                stream.feed(chunk)
            return "\n".join(screen.display)
        def send(data): os.write(master,data)
        config = self.folder / "systemone.json"
        config.write_text(json.dumps({"question":"Approved?"}))
        node = None
        try:
            node = self.node("--config",str(config),stdin=slave,stdout=slave,stderr=slave)
            wait(self.manifest)
            self.connect()
            self.call(1,"graph.emit",output="result",payload={"text":"hello"})
            wait(lambda: "Setup paused" in drain())
            time.sleep(.4)
            self.assertEqual(self.requests, [])  # no provider: initial setup even with key + question
            self.assertIn("openrouter", drain())
            self.assertNotIn("Credential name", drain())
            self.assertTrue(screen.cursor.hidden)  # enum fields are selectors, not text editors
            send(b"\x1b[<0;3;5M\x1b[<0;3;5m")  # click Provider
            wait(lambda: "custom" in drain())
            send(b"\x1b[B\x1b")  # highlight custom, then cancel
            wait(lambda: "custom" not in drain())
            send(b"\x1b[200~invalid-provider\x1b[201~\x13")
            wait(lambda: "Settings saved" in drain())
            self.assertEqual(json.loads(config.read_text())["provider"], "openrouter")
            send(b"\t\t\t\t\t\x1b[17~\x1b[200~" + "한글 Test".encode() + b"\x1b[201~")
            wait(lambda: "한글 Test" in drain())
            self.assertEqual((screen.cursor.x, screen.cursor.y), (10, 10))
            send(b"\x01\x06\x06\x15")  # Ctrl+A, two Ctrl+F, Ctrl+U: remove the two wide glyphs
            wait(lambda: "한글 Test" not in drain())
            self.assertIn(" Test", screen.display[10])
            self.assertEqual((screen.cursor.x, screen.cursor.y), (1, 10))
            send(b"\x1a\x05")  # Ctrl+Z restores; Ctrl+E moves to line end
            wait(lambda: "한글 Test" in drain())
            self.assertEqual((screen.cursor.x, screen.cursor.y), (10, 10))
            send(b"\x1b[Z" * 5)  # return to provider in the compact layout
            send(b"\t\t\t\x1bOQ")  # mode field, F2 opens its dropdown
            wait(lambda: "choice" in drain() and "score" in drain())
            send(b"\x1b[B\r")  # commit choice
            send(b"\t\t\t\x1b[17~")  # outputs, F6 selects entire JSON textarea
            outputs = [{"id":"True","name":"Approved","description":"Yes","color":"#aabbcc"},
                       {"id":"retry","description":"Try again"}]
            send(b"\x1b[200~" + json.dumps(outputs).encode() + b"\x1b[201~\x13")
            wait(lambda: (drain(), json.loads(config.read_text()).get("mode") == "choice")[1])
            saved = json.loads(config.read_text())
            self.assertEqual(saved["mode"],"choice")
            self.assertNotIn("api_key_env", saved)
            self.assertNotIn("test-secret",config.read_text())
            self.answer = {"type":"choice","choice":"True"}
            send(b"\x1b[13;5u")
            wait(lambda: (drain(),self.manifest())[1]["outputs"][0]["name"] == "Approved")
            wait(lambda: (drain(),self.inbox(4))[1])
            ports = self.manifest()["outputs"]
            self.assertEqual([p["id"] for p in ports],["True","retry"])
            edges = self.call(1,"graph.list")["edges"]
            self.assertTrue(any(e.get("from_port") == "True" for e in edges))
            self.assertFalse(any(e.get("from_port") == "False" for e in edges))
            wait(lambda: "→ True" in drain())
            self.assertIn("Log",drain())
            self.assertFalse(screen.cursor.hidden)
            self.assertEqual(screen.cursor.y, 15)  # log repaint keeps the caret in Outputs
            # Pending requests must not route with old settings after an edit.
            self.delay = 1
            self.call(1,"graph.emit",output="result",payload={"text":"second"})
            wait(lambda: (drain(),len(self.requests))[1] == 2)
            send(b" ")
            wait(lambda: "Discarded decision" in drain())
            self.assertEqual(len(self.inbox(4)),1)
            self.assertEqual(len(self.inbox(3)),1)
            self.delay = 0
            send(b"\x1b[13;5u")
            wait(lambda: (drain(),len(self.inbox(4)))[1] == 2)
            send(b"\x03")
            wait(lambda: (drain(),node.poll())[1] is not None)
            self.assertEqual(node.returncode,0)
            self.assertEqual(termios.tcgetattr(slave),before)
            self.assertNotIn(b"test-secret",captured)
        finally:
            if node: stop(node)
            os.close(master)
            os.close(slave)


if __name__ == "__main__": unittest.main()
