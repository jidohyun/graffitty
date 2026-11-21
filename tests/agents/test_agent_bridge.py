"""Local bridge contract tests. No model API or Telegram traffic."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "dist/bin/gft"


class AgentBridgeTests(unittest.TestCase):
    def worker(self, directory, request):
        path = directory / "request.json"
        path.write_text(json.dumps(request))
        result = subprocess.run([BIN, "internal", "agent-worker", "--request", path], capture_output=True, text=True, timeout=10)
        return result, json.loads(result.stdout)

    def test_transcript_checkpoint_and_unicode(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            path = directory / "session.jsonl"
            first = json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n"
            last = json.dumps({"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": "완료"}}) + "\n"
            path.write_text(first + last + '{"partial":')
            result, value = self.worker(directory, {"op": "read", "path": str(path), "offset": float(len(first.encode()))})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(value["last_message"], "완료")
            self.assertEqual(value["status"], "idle")
            self.assertEqual(value["next_offset"], len((first + last).encode()))
            self.assertNotIn("partial", value["text"])
            large = json.dumps({"message": {"role": "assistant", "content": [{"text": "x" * 150000}]}}) + "\n"
            path.write_text(large)
            result, value = self.worker(directory, {"op": "read", "path": str(path), "offset": 0})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(value["next_offset"], len(large.encode()))
            self.assertEqual(len(value["last_message"]), 150000)

    def test_discovery_keeps_concurrent_claude_homes_separate(self):
        import pty
        import shutil
        import signal
        import time
        import uuid
        with tempfile.TemporaryDirectory(prefix="alm-homes-", dir="/tmp") as tmp:
            directory = Path(tmp)
            executable = directory / "claude"
            shutil.copy("/bin/sleep", executable)
            children, roots, expected = [], [], {}
            try:
                for index in range(2):
                    pid, fd = pty.fork()
                    if pid == 0:
                        os.execv(str(executable), [str(executable), "30"])
                    children.append((pid, fd))
                    home = directory / f"account {index}"
                    (home / "sessions").mkdir(parents=True)
                    session = str(uuid.uuid4())
                    (home / "sessions" / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": session, "status": "idle", "messagingSocketPath": str(home / "socket")}))
                    node = f"%{index}"
                    roots.append({"node": node, "pid": float(pid), "agent_pid": float(pid), "provider_home": str(home)})
                    expected[node] = (home, session)
                for _ in range(30):
                    result, value = self.worker(directory, {"op": "scan", "roots": roots})
                    if len(value) == 2:
                        break
                    time.sleep(.1)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(value), 2, value)
                for node, (home, session) in expected.items():
                    self.assertEqual(value[node]["session_id"], session)
                    self.assertEqual(value[node]["registry_dir"], str(home / "sessions"))
                    self.assertEqual(value[node]["socket_path"], str(home / "socket"))
            finally:
                for pid, fd in children:
                    os.kill(pid, signal.SIGTERM)
                    os.waitpid(pid, 0)
                    os.close(fd)

    def test_codex_without_lifecycle_evidence_is_unknown(self):
        import pty
        import shutil
        import signal
        import time
        with tempfile.TemporaryDirectory(prefix="alm-codex-", dir="/tmp") as tmp:
            directory = Path(tmp)
            executable = directory / "codex"
            shutil.copy("/bin/sleep", executable)
            pid, fd = pty.fork()
            if pid == 0:
                os.execv(str(executable), [str(executable), "30"])
            try:
                for _ in range(30):
                    result, value = self.worker(directory, {"op": "scan", "roots": [{"node": "%1", "pid": float(pid)}]})
                    if "%1" in value:
                        break
                    time.sleep(.1)
                self.assertEqual(value["%1"]["status"], "unknown")
                self.assertEqual(value["%1"]["provider"], "codex")
            finally:
                os.kill(pid, signal.SIGTERM)
                os.waitpid(pid, 0)
                os.close(fd)

    def test_exited_agent_is_reported_offline(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, value = self.worker(Path(tmp), {"op": "scan", "roots": [
                {"node": "%2", "pid": -1, "agent_pid": 2147483647.0},
                {"node": "%3", "pid": -1}
            ]})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(value, {"%2": {"status": "offline"}})

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS peer PID verification")
    def test_claude_authenticated_wire_and_stale_pid_rejection(self):
        with tempfile.TemporaryDirectory(prefix="alm-bridge-", dir="/tmp") as tmp:
            directory = Path(tmp)
            endpoint = directory / "inbox.sock"
            frames = []
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(endpoint))
                server.listen(1)
                server.settimeout(5)
                def receive():
                    with server.accept()[0] as client:
                        frames.extend(json.loads(line) for line in client.makefile())
                thread = threading.Thread(target=receive)
                thread.start()
                pid = os.getpid()
                started = " ".join(subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart="], text=True, env=dict(os.environ, TZ="UTC", LC_ALL="C")).split())
                digest = hashlib.sha256(str(endpoint).encode()).hexdigest()
                key = directory / f"{pid}.{digest}.key"
                key.write_text(json.dumps({"peerToken": "f" * 32}))
                key.chmod(0o600)
                target = {"pid": float(pid), "started": started, "socket_path": str(endpoint), "registry_dir": str(directory)}
                result, value = self.worker(directory, {"op": "claude_send", "target": target, "text": "test message", "event_id": "a" * 32})
                thread.join(5)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(value["status"], "submitted")
                self.assertEqual(frames[0], {"type": "auth", "token": "f" * 32})
                self.assertEqual(frames[1]["message"]["content"], "test message")
                self.assertNotIn("f" * 32, result.stdout + result.stderr)
                target["started"] = "a different process"
                result, value = self.worker(directory, {"op": "claude_send", "target": target, "text": "must not send", "event_id": "b" * 32})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("changed", value["error"]["message"])

    def test_removed_telegram_command_is_not_a_compatibility_alias(self):
        # Delivery and secret handling are covered by test_chat_integrations
        # using the current node telegram-send interface and offline fixtures.
        result = subprocess.run([BIN, "telegram", "--stdin"], input="", text=True,
                                capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecognized subcommand", result.stderr)


if __name__ == "__main__":
    unittest.main()
