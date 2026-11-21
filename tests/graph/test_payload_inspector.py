"""Real inspector CLI + host socket fan-out. Run: uv run tests/graph/test_payload_inspector.py"""
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_parallel_node import ROOT, rpc, wait, stop


class PayloadInspectorIntegration(unittest.TestCase):
    def test_fanout_complete_events_restart_and_no_stdin(self):
        with tempfile.TemporaryDirectory(prefix="inspect-", dir="/tmp") as folder:
            folder = Path(folder)
            with (folder / "host.log").open("w+") as host_log, (folder / "events.jsonl").open("w+") as output:
                host = subprocess.Popen(
                    ["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"), "--script", "tests/jev_node_host.gd"],
                    env={**os.environ, "JEV_TEST_DIRECTORY": str(folder)}, stdout=host_log, stderr=host_log)
                node = None
                try:
                    wait(lambda: (folder / "ready.json").exists())
                    endpoint = json.loads((folder / "ready.json").read_text())["socket"]
                    def call(token, method, **params):
                        return rpc(endpoint, token, method, params)
                    def launch(*args):
                        isolated = {key:value for key,value in os.environ.items()
                                    if key not in {"CODEX_THREAD_ID", "GRAFFITTY_CODEX_CONTEXT"}}
                        return subprocess.Popen(
                            [os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "dist/bin/gft")), "node", "payload-inspector", *args],
                            env={**isolated, "GRAFFITTY_SOCKET": endpoint, "GRAFFITTY_TOKEN": "3"},
                            stdin=subprocess.DEVNULL, stdout=output, stderr=host_log)
                    def captured():
                        return [json.loads(line) for line in (folder / "events.jsonl").read_text().splitlines()]
                    node = launch("--json")
                    manifest = wait(lambda: next((n.get("manifest") for n in call(1, "graph.list")["nodes"]
                        if n["node"] == "%3" and n.get("manifest", {}).get("name") == "Payload Inspector"), None))
                    self.assertEqual(manifest["inputs"][0]["id"], "payload")
                    self.assertEqual(manifest["outputs"], [])
                    call(1, "agent.event", kind="custom", event="SessionStart")
                    call(1, "agent.register", name="Source", inputs=[], outputs=[{"id": "result"}])
                    for target, port in [(3, "payload"), (4, "in")]:
                        call(1, "graph.connect", **{"from":"%1", "from_port":"result", "to":f"%{target}", "to_port":port})
                    payload = {"text":"hello\nsecond line", "nested":{"arbitrary":[None, False, 42, "한글"]}}
                    call(1, "graph.emit", output="result", payload=payload)
                    wait(lambda: not call(3, "graph.take")["events"] and bool((folder / "events.jsonl").read_text()))
                    event = captured()[0]
                    self.assertEqual(event["sessions"], [])
                    self.assertEqual(event["payload"], payload)
                    self.assertNotIn("\u001b", (folder / "events.jsonl").read_text())
                    other = call(4, "graph.take")["events"]
                    self.assertEqual(len(other), 1)
                    self.assertEqual(other[0]["payload"], payload)
                    self.assertNotEqual(other[0]["event_id"], event["event_id"])
                    self.assertEqual(other[0]["run_id"], event["run_id"])
                    # Its own acknowledgment must not consume or acknowledge the sibling.
                    receipts = call(1, "graph.list")["receipts"]
                    self.assertTrue(any(r["event_id"] == event["event_id"] and r["status"] == "delivered" for r in receipts))
                    stop(node)
                    self.assertEqual(node.returncode, 0)
                    # Queue while offline, then resume without losing the pending capture.
                    call(1, "graph.emit", output="result", payload=["non-object", {"value": True}])
                    self.assertEqual(len(call(3, "graph.take")["events"]), 1)
                    node = launch("--json", "--once", "--name", "Debug branch")
                    node.wait(timeout=10)
                    self.assertEqual(node.returncode, 0)
                    self.assertEqual(captured()[1]["payload"], ["non-object", {"value": True}])
                    self.assertEqual(call(3, "graph.take")["events"], [])
                    self.assertEqual(len(call(4, "graph.take")["events"]), 2)
                    # Built-in Turn completion notifications retain session paths and checkpoints.
                    session = folder / "claude.jsonl"
                    session.write_text('{"custom":"not normalized"}\n')
                    call(2, "agent.event", provider="claude", event="SessionStart", session_id="claude-session", transcript_path=str(session))
                    call(2, "graph.connect", **{"from":"%2", "from_port":"turn_completed", "to":"%3", "to_port":"payload"})
                    call(2, "agent.event", provider="claude", event="Stop", text="Finished review")
                    node = launch("--json", "--once")
                    node.wait(timeout=10)
                    self.assertEqual(node.returncode, 0)
                    notification = captured()[2]
                    self.assertEqual(notification["text"], "Finished review")
                    self.assertEqual(notification["sessions"][0]["path"], str(session))
                    self.assertGreater(notification["sessions"][0]["checkpoint"]["byte_offset"], 0)
                    # The default display is indented JSON, also preserving the envelope.
                    call(1, "graph.emit", output="result", payload={"text":"pretty"})
                    offset = (folder / "events.jsonl").stat().st_size
                    started = datetime.now(timezone.utc).replace(microsecond=0)
                    node = launch("--once")
                    node.wait(timeout=10)
                    self.assertEqual(node.returncode, 0)
                    pretty = (folder / "events.jsonl").read_bytes()[offset:].decode()
                    header, pretty = pretty.split("\n", 1)
                    timestamp = datetime.strptime(header, "[%Y-%m-%d %H:%M:%S %z]")
                    self.assertGreaterEqual(timestamp, started)
                    self.assertLessEqual(timestamp, datetime.now(timezone.utc))
                    self.assertIn('\n  "', pretty)
                    self.assertEqual(json.loads(pretty)["payload"], {"text":"pretty"})
                finally:
                    if node is not None:
                        stop(node)
                    stop(host)


if __name__ == "__main__":
    unittest.main()
