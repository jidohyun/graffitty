"""Real Parallel CLI + Godot graph/socket, no stdin, model, or external service.
Run: uv run tests/graph/test_parallel_node.py
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]


def rpc(endpoint, token, method, params):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(5)
        peer.connect(str(endpoint))
        request = dict(id=str(uuid.uuid4()), version=1, token=str(token), method=method, params=params)
        peer.sendall((json.dumps(request) + "\n").encode())
        reply = json.loads(peer.makefile("rb").readline())
        assert reply["id"] == request["id"]
        assert "error" not in reply, reply
        return reply["result"]


def wait(check):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError("Timed out waiting for node")


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


class ParallelIntegration(unittest.TestCase):
    def test_socket_join_fifo_sessions_progress_and_clean_exit(self):
        env = {key: value for key, value in os.environ.items()
               if key not in {"CODEX_THREAD_ID", "GRAFFITTY_CODEX_CONTEXT"}}
        with tempfile.TemporaryDirectory(prefix="parallel-", dir="/tmp") as folder:
            folder = Path(folder)
            with (folder / "host.log").open("w+") as host_log, (folder / "node.log").open("w+") as node_log:
                host = subprocess.Popen(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"), "--script", "tests/jev_node_host.gd"],
                    env={**env, "JEV_TEST_DIRECTORY": str(folder)}, stdout=host_log, stderr=host_log)
                node = None
                try:
                    wait(lambda: (folder / "ready.json").exists())
                    endpoint = json.loads((folder / "ready.json").read_text())["socket"]
                    node = subprocess.Popen([os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "dist/bin/gft")), "node", "parallel", "--name", "Review join"],
                        env={**env, "GRAFFITTY_SOCKET": endpoint, "GRAFFITTY_TOKEN": "3"},
                        stdin=subprocess.DEVNULL, stdout=node_log, stderr=node_log)
                    def manifest():
                        nodes = rpc(endpoint, 1, "graph.list", {})["nodes"]
                        return next((n.get("manifest") for n in nodes if n["node"] == "%3" and n.get("manifest", {}).get("name") == "Review join"), None)
                    registration = wait(manifest)
                    self.assertEqual(registration["inputs"][0]["id"], "join")
                    self.assertEqual(registration["outputs"][0]["id"], "combined")
                    paths = []
                    for source, provider in [(1, "codex"), (2, "claude")]:
                        path = folder / f"{provider}.jsonl"
                        path.write_text('{"custom":"preserve this file; do not normalize"}\n')
                        paths.append(str(path))
                        rpc(endpoint, source, "agent.event", dict(provider=provider, event="SessionStart", session_id=f"session-{source}", transcript_path=str(path)))
                        rpc(endpoint, source, "graph.connect", {"from":f"%{source}", "from_port":"turn_completed", "to":"%3", "to_port":"join"})
                    def notify(source, text):
                        return rpc(endpoint, source, "agent.event", {"provider":"codex" if source == 1 else "claude", "event":"Stop", "text":text})
                    def inbox(token):
                        return rpc(endpoint, token, "graph.take", {})["events"]
                    notify(1, "A first")
                    notify(1, "A second")
                    wait(lambda: "1/2  50%" in (folder / "node.log").read_text())
                    log = (folder / "node.log").read_text()
                    self.assertIn("[x] Worker 1 / turn_completed", log)
                    self.assertIn("[ ] Worker 2 / turn_completed", log)
                    self.assertNotIn("%1", log)
                    pending = wait(lambda: next((r for r in rpc(endpoint, 1, "graph.list", {})["receipts"] if r["status"] == "pending"), None))
                    self.assertEqual(pending["details"]["received"], 1)
                    self.assertEqual(pending["details"]["total"], 2)
                    self.assertEqual(pending["details"]["waiting_for"][0]["title"], "Worker 2")
                    self.assertEqual(inbox(4), [])
                    self.assertEqual(len(inbox(3)), 2, "Incomplete inputs stay in host")
                    notify(2, "B first")
                    wait(lambda: "All arrived. Connect Combined" in (folder / "node.log").read_text())
                    self.assertEqual(inbox(4), [])
                    rpc(endpoint, 3, "graph.connect", {"from":"%3", "from_port":"combined", "to":"%4", "to_port":"in"})
                    wait(lambda: len(inbox(4)) == 1)
                    first = inbox(4)[0]
                    self.assertEqual(first["source_port"], "combined")
                    self.assertEqual(first["payload"]["type"], "parallel.completed")
                    self.assertEqual(first["kind"], "parallel.completed")
                    self.assertEqual([ref["path"] for ref in first["sessions"]], paths)
                    inputs = first["payload"]["inputs"]
                    self.assertEqual([e["text"] for e in inputs], ["A first", "B first"])
                    self.assertEqual([e["sessions"][0]["path"] for e in inputs], paths)
                    self.assertTrue(all(e["sessions"][0]["checkpoint"]["byte_offset"] > 0 for e in inputs))
                    self.assertTrue(all(p in first["text"] for p in paths))
                    self.assertEqual(first["run_id"], inputs[0]["run_id"])
                    wait(lambda: len(inbox(3)) == 1)
                    receipts = rpc(endpoint, 1, "graph.list", {})["receipts"]
                    self.assertTrue(any(r["event_id"] == pending["event_id"] and r["status"] == "delivered" for r in receipts))
                    self.assertFalse(any(r["event_id"] == pending["event_id"] and r["status"] == "pending" for r in receipts))
                    notify(2, "B second")
                    wait(lambda: len(inbox(4)) == 2)
                    second = inbox(4)[1]
                    self.assertEqual([e["text"] for e in second["payload"]["inputs"]], ["A second", "B second"])
                    self.assertEqual(second["payload"]["round"], 2)
                    wait(lambda: not inbox(3))
                    time.sleep(.7)
                    self.assertEqual(len(inbox(4)), 2, "Repeated polling cannot duplicate a round")
                    stop(node)
                    self.assertEqual(node.returncode, 0)
                    nodes = rpc(endpoint, 1, "graph.list", {})["nodes"]
                    self.assertEqual(next(n for n in nodes if n["node"] == "%3")["status"], "offline")
                    # A fresh CLI process must not clear an incomplete host inbox.
                    notify(1, "A after restart")
                    self.assertEqual(len(inbox(3)), 1)
                    restart_offset = len((folder / "node.log").read_text())
                    node = subprocess.Popen([os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "dist/bin/gft")), "node", "parallel", "--once"],
                        env={**env, "GRAFFITTY_SOCKET": endpoint, "GRAFFITTY_TOKEN": "3"},
                        stdin=subprocess.DEVNULL, stdout=node_log, stderr=node_log)
                    wait(lambda: "1/2  50%" in (folder / "node.log").read_text()[restart_offset:])
                    self.assertEqual(len(inbox(3)), 1)
                    notify(2, "B after restart")
                    node.wait(timeout=10)
                    self.assertEqual(node.returncode, 0)
                    self.assertEqual(len(inbox(4)), 3)
                    self.assertEqual([e["text"] for e in inbox(4)[2]["payload"]["inputs"]], ["A after restart", "B after restart"])

                except Exception:
                    node_log.flush()
                    print((folder / "node.log").read_text())
                    raise
                finally:
                    if node is not None: stop(node)
                    stop(host)


if __name__ == "__main__":
    unittest.main()
