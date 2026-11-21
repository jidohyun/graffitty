"""OpenCode v2 in-process integration contracts: no credentials or paid model requests."""
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "dist/bin/gft"))


class OpenCodeIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gft-opencode-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GRAFFITTY_", "CODEX_", "OPENCODE_", "PI_CODING_AGENT_", "XDG_"))}
        self.env["OPENCODE_CONFIG_DIR"] = str(self.home / "config")
        # An account alias selects OpenCode's data directory for one process.
        self.env["XDG_DATA_HOME"] = str(self.home / "account")
        self.requests, self.queue = [], []
        self.typing = False
        self.transport = None
        self.watches = []
        self.watch_lock = threading.Lock()
        self.keepalive_at = time.monotonic()
        self.done = threading.Event()
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(self.home / "rpc.sock"))
        self.socket.listen(16)
        self.socket.settimeout(.1)
        self.env.update(GRAFFITTY_SOCKET=str(self.home / "rpc.sock"), GRAFFITTY_TOKEN="private-test-token")
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.child = None
        self.provider = "opencode"

    def stop_server(self):
        if self.child is not None and self.child.poll() is None:
            self.child.stdin.close()
            self.child.wait(timeout=5)
            self.child.stdout.close()
            self.child.stderr.close()
        self.done.set()
        self.thread.join(3)
        self.socket.close()
        with self.watch_lock:
            for peer in self.watches:
                peer.close()
            self.watches.clear()

    def publish(self, method="graph.changed"):
        payload = (json.dumps({"version": 1, "method": method, "params": {}}) + "\n").encode()
        with self.watch_lock:
            for peer in self.watches[:]:
                try:
                    peer.sendall(payload)
                except OSError:
                    self.watches.remove(peer)
                    peer.close()

    def serve(self):
        while not self.done.is_set():
            try:
                peer, _ = self.socket.accept()
            except socket.timeout:
                if time.monotonic() - self.keepalive_at >= 5:
                    self.publish("graph.keepalive")
                    self.keepalive_at = time.monotonic()
                continue
            with peer:
                request = json.loads(peer.makefile().readline())
                self.requests.append(request)
                method, p = request["method"], request["params"]
                if method == "graph.watch":
                    peer.sendall((json.dumps({"id": request["id"], "version": 1, "result": {"watching": True}}) + "\n").encode())
                    with self.watch_lock:
                        self.watches.append(peer.dup())
                    continue
                result = {"events": self.queue.copy()} if method == "graph.take" else {"ok": True}
                if method == "agent.event":
                    # Like the server: the reply carries the registered transport,
                    # and a missing one asks the integration to register again.
                    if p["event"] == "SessionStart":
                        self.transport = p.get("transport")
                    result = {"ok": True, "transport": self.transport}
                if method == "agent.delivery":
                    result = {"ready": not self.typing and any(e["event_id"] == p["event_id"] for e in self.queue)}
                if method == "graph.ack":
                    self.queue = [e for e in self.queue if e["event_id"] != p["event_id"]]
                if method == "graph.adjacent":
                    result = {"incoming": [], "outgoing": [{"to": "%2", "send": True}]}
                peer.sendall((json.dumps({"id": request["id"], "result": result}) + "\n").encode())

    def cli(self, *args, input=None):
        return subprocess.run([BIN, *args], env=self.env, input=json.dumps(input) if input is not None else None,
                              text=True, capture_output=True, timeout=10)

    def plugin_directory(self):
        if self.provider == "pi":
            return Path(self.env["PI_CODING_AGENT_DIR"]) / "extensions/graffitty"
        return Path(self.env["OPENCODE_CONFIG_DIR"]) / "plugins/graffitty"

    def plugin(self, mode, input=None):
        return subprocess.run(["node", str(ROOT / "tests/fixtures/integration-runtime.mjs"), self.provider,
                               str(self.plugin_directory()), mode], env=self.env,
                              input=json.dumps(input or {}) + "\n", text=True, capture_output=True, timeout=10)

    def start(self):
        installed = self.cli("integrate", "agent", self.provider, "--apply")
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.child = subprocess.Popen(["node", str(ROOT / "tests/fixtures/integration-runtime.mjs"), self.provider,
                                      str(self.plugin_directory())], env=self.env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        return self.next()

    def next(self):
        ready, _, _ = select.select([self.child.stdout], [], [], 5)
        self.assertTrue(ready, "native runtime did not request a host operation")
        line = self.child.stdout.readline()
        self.assertTrue(line, self.child.stderr.read() if self.child.poll() is not None else "runtime EOF")
        return json.loads(line)

    def reply(self, request, result):
        self.child.stdin.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        self.child.stdin.flush()
        return self.next()

    def snapshot(self, messages, session="ses_test", pending=None, status="idle"):
        return dict(sessionID=session, pid=os.getpid(), messages=messages, pending=pending or [], status=status, waiting=False)

    def lifecycle(self, event):
        return [r["params"] for r in self.requests if r["method"] == "agent.event" and r["params"]["event"] == event]

    def test_install_preview_idempotent_remove_preserves_other_plugins(self):
        config = Path(self.env["OPENCODE_CONFIG_DIR"])
        preview = self.cli("integrate", "agent", "opencode")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertFalse(config.exists())
        self.assertNotEqual(self.cli("integrate", "agent", "opencode", "--status").returncode, 0)
        self.assertFalse(config.exists())
        config.mkdir()
        other = config / "opencode.json"
        other.write_text('{"keep":"this"}')
        result = self.cli("integrate", "agent", "opencode", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        before = {p: p.read_bytes() for p in config.rglob("*") if p.is_file()}
        self.assertEqual(self.cli("integrate", "agent", "opencode", "--apply").returncode, 0)
        self.assertEqual(before, {p: p.read_bytes() for p in config.rglob("*") if p.is_file()})
        self.assertEqual(self.cli("integrate", "agent", "opencode", "--status").returncode, 0)
        self.assertEqual(self.cli("integrate", "agent", "opencode", "--remove", "--apply").returncode, 0)
        self.assertEqual(other.read_text(), '{"keep":"this"}')

    def test_input_wait_resumes_without_completing_a_turn(self):
        request = self.start()
        snapshot = self.snapshot([], status="running")
        request = self.reply(request, snapshot)
        snapshot["waiting"] = True
        request = self.reply(request, snapshot)
        request = self.reply(request, snapshot)
        self.assertEqual(len(self.lifecycle("AwaitingInput")), 1)
        self.assertEqual(self.lifecycle("Stop"), [])
        snapshot["waiting"] = False
        request = self.reply(request, snapshot)
        self.assertEqual(len(self.lifecycle("PreToolUse")), 2)
        request = self.reply(request, self.snapshot([]))
        self.assertEqual(len(self.lifecycle("Ready")), 1)
        self.assertEqual(self.lifecycle("Stop"), [])

    def test_completion_uses_idle_markers_not_tool_steps_or_old_history(self):
        request = self.start()
        messages = [{"id": "msg_old", "type": "idle", "outcome": "succeeded"}]
        request = self.reply(request, self.snapshot(messages))
        self.assertEqual(self.lifecycle("Stop"), [])
        for n in range(2):
            messages += [{"id": f"msg_user{n}", "type": "user", "text": "same question"},
                         {"id": f"msg_assistant{n}", "type": "assistant", "content": [{"type": "text", "text": "Same reply"}]}]
            request = self.reply(request, self.snapshot(messages, status="running"))
            self.assertEqual(len(self.lifecycle("Stop")), n)
            messages += [{"id": f"msg_idle{n}", "type": "idle", "outcome": "succeeded"}]
            request = self.reply(request, self.snapshot(messages))
        self.assertEqual([e["text"] for e in self.lifecycle("Stop")], ["Same reply", "Same reply"])
        start = self.lifecycle("SessionStart")[0]
        self.assertEqual((start["provider"], start["kind"], start["transport"]), ("opencode", "agent", "inbox"))
        # OpenCode v2 declares its own relaunch: continue this session in this
        # process's own account and config, removing locations it did not have.
        restore = start["restore"]
        self.assertEqual((Path(restore["command"][0]).name, restore["command"][1:]), ("opencode", ["--session", "ses_test"]))
        self.assertEqual(restore["env"], {"XDG_DATA_HOME": self.env["XDG_DATA_HOME"], "OPENCODE_CONFIG_DIR": self.env["OPENCODE_CONFIG_DIR"],
                                          "XDG_CONFIG_HOME": None, "XDG_STATE_HOME": None, "XDG_CACHE_HOME": None,
                                          "OPENCODE_CONFIG": None, "OPENCODE_DB": None})
        transcript = Path(start["transcript_path"])
        self.assertEqual(transcript.stat().st_mode & 0o777, 0o600)
        self.assertEqual([json.loads(line) for line in transcript.read_text().splitlines()], messages)
        context = self.plugin("context", input={"sessionID": "ses_test"})
        self.assertEqual(context.returncode, 0, context.stderr)
        self.assertIn("graffitty tool", context.stdout)
        self.assertNotIn("private-test-token", context.stdout)
        result = self.plugin("tool", input={"sessionID": "ses_test", "method": "graph.send", "params": {"to": "%2", "text": "reply"}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[-1]["token"], "private-test-token")

    def test_home_screen_is_ready_without_inventing_a_conversation(self):
        request = self.reply(self.start(), self.snapshot([], session=""))
        self.assertEqual(len(self.lifecycle("SessionStart")), 1, "The connected home screen must register readiness")
        start = self.lifecycle("SessionStart")[0]
        self.assertEqual((start["provider"], start["transport"], start["pid"]), ("opencode", "native", os.getpid()))
        self.assertTrue(start["integrated"])
        self.assertNotIn("session_id", start)
        self.assertNotIn("transcript_path", start)
        self.assertNotIn("restore", start, "A home screen has no conversation to reopen")
        self.assertFalse(any(r["method"] == "graph.take" for r in self.requests))
        request = self.reply(request, self.snapshot([], session=""))
        self.assertEqual(len(self.lifecycle("SessionStart")), 1)
        request = self.reply(request, self.snapshot([]))
        events = [r["params"] for r in self.requests if r["method"] == "agent.event"]
        self.assertEqual([e["event"] for e in events], ["SessionStart", "SessionEnd", "SessionStart"])
        self.assertEqual(events[-1]["session_id"], "ses_test")
        request = self.reply(request, self.snapshot([], session=""))
        self.assertNotIn("session_id", self.lifecycle("SessionStart")[-1])
        self.assertEqual(self.lifecycle("Stop"), [])
        self.assertEqual(self.plugin("context", input={"sessionID": "ses_test"}).stdout, "")
        self.child.stdin.close()
        self.child.wait(timeout=5)
        self.child.stdout.close()
        self.child.stderr.close()
        self.assertEqual(len(self.lifecycle("SessionEnd")), 3)

    def test_fast_first_turn_and_failed_turn_do_not_replay_old_answer(self):
        request = self.start()
        messages = [{"id": "msg_first", "type": "user", "text": "hello"},
                    {"id": "msg_answer", "type": "assistant", "content": [{"type": "text", "text": "first reply"}]},
                    {"id": "msg_done", "type": "idle", "outcome": "succeeded", "time": {"created": int(time.time() * 1000) + 1}}]
        request = self.reply(request, self.snapshot(messages))
        self.assertEqual(self.lifecycle("Stop")[0]["text"], "first reply")
        messages += [{"id": "msg_second", "type": "user", "text": "another question"},
                     {"id": "msg_failed", "type": "idle", "outcome": "failed"}]
        self.reply(request, self.snapshot(messages))
        self.assertEqual(self.lifecycle("Stop")[-1]["text"], "")
        self.assertEqual(self.lifecycle("Stop")[-1]["outcome"], "error")

    def test_structured_assistant_failure_excludes_user_interrupt(self):
        request = self.reply(self.start(), self.snapshot([]))
        created = int(time.time() * 1000) + 1
        messages = [{"id": "msg_question", "type": "user", "text": "hello"},
                    {"id": "msg_error", "type": "assistant", "content": [],
                     "error": {"type": "unknown", "message": "API quota exceeded"},
                     "time": {"created": created}}]
        request = self.reply(request, self.snapshot(messages))
        self.assertEqual(self.lifecycle("Error")[-1]["text"], "API quota exceeded")
        request = self.reply(request, self.snapshot(messages))
        self.assertEqual(len(self.lifecycle("Error")), 1)
        messages += [{"id": "msg_retry", "type": "user", "text": "retry"},
                     {"id": "msg_abort", "type": "assistant", "content": [],
                      "error": {"type": "unknown", "message": "Provider turn interrupted"},
                      "time": {"created": created + 1}}]
        request = self.reply(request, self.snapshot(messages))
        self.assertEqual(len(self.lifecycle("Error")), 1)
        messages += [{"id": "msg_abort_idle", "type": "idle", "outcome": "failed", "time": {"created": created + 2}}]
        self.reply(request, self.snapshot(messages))
        self.assertEqual(self.lifecycle("Stop")[-1]["outcome"], "interrupted")
        self.assertEqual(len(self.lifecycle("Error")), 1)

    def test_typing_defers_native_queue_submission(self):
        request = self.reply(self.start(), self.snapshot([]))
        self.queue = [{"event_id": "quiet", "source": "%2", "target": "%1", "text": "after typing"}]
        self.typing = True
        request = self.reply(request, self.snapshot([]))
        self.assertEqual(request["op"], "snapshot")
        self.typing = False
        request = self.reply(request, self.snapshot([]))
        self.assertEqual(request["op"], "prompt")
        self.reply(request, {})

    def test_native_queue_ack_only_on_execution_and_cancel_on_revocation(self):
        request = self.start()
        request = self.reply(request, self.snapshot([]))
        event = {"event_id": "queued-event", "source": "%2", "target": "%1", "run_id": "causal-run", "text": "Implement it", "sessions": []}
        self.queue = [event]
        request = self.reply(request, self.snapshot([], status="running"))
        self.assertEqual(request["op"], "prompt")
        self.assertIn("run causal-run]", request["text"])
        message_id = request["messageID"]
        request = self.reply(request, {})
        self.assertFalse(any(r["method"] == "graph.ack" for r in self.requests))
        self.queue = []  # muted/disconnected edge
        request = self.reply(request, self.snapshot([], pending=[{"id": message_id}], status="running"))
        self.assertEqual(request["op"], "cancel")
        self.assertEqual(request["messageID"], message_id)
        request = self.reply(request, {})
        self.queue = [{**event, "event_id": "next-event"}]
        request = self.reply(request, self.snapshot([]))
        message_id = request["messageID"]
        prompt = request["text"]
        request = self.reply(request, {})
        request = self.reply(request, self.snapshot([{"id": message_id, "type": "user", "text": prompt}], status="running"))
        self.assertEqual([r["params"]["event_id"] for r in self.requests if r["method"] == "graph.ack"], ["next-event"])

    def test_session_switch_ends_old_binding_and_does_not_replay_history(self):
        request = self.reply(self.start(), self.snapshot([]))
        request = self.reply(request, self.snapshot([{"id": "msg_past", "type": "idle", "outcome": "succeeded"}], session="ses_other"))
        self.assertEqual([e["session_id"] for e in self.lifecycle("SessionStart")], ["ses_test", "ses_other"])
        self.assertEqual(len(self.lifecycle("SessionEnd")), 1)
        self.assertEqual(self.lifecycle("Stop"), [])
        self.assertNotEqual(self.plugin("tool", input={"sessionID": "ses_test", "method": "graph.list"}).returncode, 0)
        self.assertEqual(self.plugin("context", input={"sessionID": "ses_test"}).stdout, "")

    def test_returning_to_an_internal_tab_does_not_reemit_its_completed_turn(self):
        request = self.reply(self.start(), self.snapshot([]))
        messages = [{"id": "msg_user", "type": "user", "text": "hello"},
                    {"id": "msg_done", "type": "idle", "outcome": "succeeded", "time": {"created": int(time.time() * 1000)}}]
        request = self.reply(request, self.snapshot(messages))
        self.assertEqual(len(self.lifecycle("Stop")), 1)
        request = self.reply(request, self.snapshot([], session="ses_other"))
        self.reply(request, self.snapshot(messages))
        self.assertEqual(len(self.lifecycle("Stop")), 1)

    def test_ambiguous_or_stale_session_never_uses_daemon_environment(self):
        self.reply(self.start(), self.snapshot([]))
        directory = Path(self.env["OPENCODE_CONFIG_DIR"]) / ".graffitty/bindings" / hashlib.sha256(b"ses_test").hexdigest()
        files = list(directory.glob("*.json"))
        (directory / "other.json").write_bytes(files[0].read_bytes())
        result = self.plugin("tool", input={"sessionID": "ses_test", "method": "graph.list"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple", result.stderr)
        (directory / "other.json").write_text(json.dumps({"updated": time.time() - 60, "socket": "wrong", "token": "wrong"}))
        self.assertEqual(self.plugin("tool", input={"sessionID": "ses_test", "method": "graph.list"}).returncode, 0)


if __name__ == "__main__":
    unittest.main()
