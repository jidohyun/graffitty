# /// script
# requires-python = ">=3.11"
# dependencies = ["pyte>=0.8,<1"]
# ///
"""Real jq filter CLI, host graph, and editable PTY form. No model calls.
Run: uv run tests/graph/test_filter_node.py
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import pyte
import select
import struct
import subprocess
import tempfile
import termios
import time
import unittest

from test_parallel_node import ROOT, rpc, wait, stop


class FilterIntegration(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="filter-", dir="/tmp")
        self.folder = Path(self.directory.name)
        self.logs = []
        self.processes = []
        self.host = self.start(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"), "--script", "tests/jev_node_host.gd"], {"JEV_TEST_DIRECTORY":str(self.folder)})
        wait(lambda: (self.folder / "ready.json").exists())
        self.endpoint = json.loads((self.folder / "ready.json").read_text())["socket"]
        self.env = {"GRAFFITTY_SOCKET":self.endpoint, "GRAFFITTY_TOKEN":"3"}
        self.call(1, "agent.event", provider="adapter", event="SessionStart", session_id="source")
        self.call(1, "agent.register", name="Source", inputs=[], outputs=[{"id":"result"}])
        self.call(2, "agent.register", name="Other", inputs=[{"id":"in"}], outputs=[])

    def start(self, command, env=None, **kwargs):
        log = (self.folder / f"process-{len(self.logs)}.log").open("w+")
        self.logs.append(log)
        isolated = {key: value for key, value in os.environ.items()
                    if key not in {"CODEX_THREAD_ID", "GRAFFITTY_CODEX_CONTEXT"}}
        process = subprocess.Popen(command, env={**isolated, **(env or {})}, stdin=kwargs.pop("stdin", subprocess.DEVNULL), stdout=kwargs.pop("stdout", log), stderr=kwargs.pop("stderr", log), **kwargs)
        self.processes.append(process)
        return process

    def tearDown(self):
        for process in reversed(self.processes): stop(process)
        for log in self.logs: log.close()
        self.directory.cleanup()

    def call(self, token, method, **params):
        return rpc(self.endpoint, token, method, params)

    def filter(self, *args, env=None, **kwargs):
        return self.start([os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "dist/bin/gft")), "node", "filter", *args], {**self.env, **(env or {})}, **kwargs)

    def manifest(self):
        return next((n.get("manifest") for n in self.call(1, "graph.list")["nodes"] if n["node"] == "%3" and n.get("manifest", {}).get("inputs", [{}])[0].get("id") == "in" and len(n.get("manifest", {}).get("outputs", [])) == 2), None)

    def connect(self):
        self.call(1, "graph.connect", **{"from":"%1", "from_port":"result", "to":"%3", "to_port":"in"})
        for port, target in [("matched",4),("unmatched",2)]:
            self.call(3, "graph.connect", **{"from":"%3", "from_port":port, "to":f"%{target}", "to_port":"in"})

    def inbox(self, token):
        return self.call(token, "graph.take")["events"]

    def test_config_file_and_cli_routes_transforms_and_inspector_fanout(self):
        config = self.folder / "filter.json"
        config.write_text(json.dumps({"name":"File name", "input":".payload.score", "condition":"false", "transform":'{text: ("Review: " + .text), payload: .payload}'}))
        node = self.filter("--config", str(config), "--name", "CLI name", "--condition", ". < 0.5", env={"GRAFFITTY_NODE_SETTINGS":'{"name":"Ignored removed setting","condition":"true"}'})
        manifest = wait(self.manifest)
        self.assertEqual(manifest["name"], "CLI name")
        self.assertIn("<svg", manifest["icon"]["svg"])
        self.connect()
        inspector = self.start([os.environ.get("GRAFFITTY_TEST_CLI", str(ROOT / "dist/bin/gft")), "node", "payload-inspector", "--json", "--once"], {**self.env,"GRAFFITTY_TOKEN":"5"})
        wait(lambda: any(n.get("manifest",{}).get("name") == "Payload Inspector" for n in self.call(1,"graph.list")["nodes"]))
        self.call(1,"graph.connect", **{"from":"%1","from_port":"result","to":"%5","to_port":"payload"})
        original = {"text":"check", "score":0.2,"custom":{"nested":[True,None,"한글"]}}
        self.call(1,"graph.emit",output="result",payload=original)
        event = wait(lambda: self.inbox(4))[0]
        self.assertEqual(event["text"],"Review: check")
        self.assertEqual(event["payload"],original)
        self.assertEqual(event["origin"]["source"],"%1")
        self.assertTrue(event["caused_by"])
        inspector.wait(timeout=10)
        self.assertEqual(inspector.returncode,0)
        capture = json.loads(Path(self.logs[-1].name).read_text())
        self.assertEqual(capture["payload"], original)
        self.assertEqual(capture["text"],"check")
        self.call(1,"graph.emit",output="result",payload={"text":"pass","score":0.8})
        self.assertEqual(wait(lambda:self.inbox(2))[0]["text"],"Review: pass")
        wait(lambda: not self.inbox(3))
        stop(node)
        self.assertEqual(node.returncode,0)

    def test_stop_session_forwarding_and_errors_retained_for_restart(self):
        node = self.filter("--condition", 'contains("error")')
        wait(self.manifest)
        self.connect()
        self.call(1,"graph.emit",output="result",payload={"text":"okay"})
        self.assertEqual(wait(lambda:self.inbox(2))[0]["text"],"okay")
        stop(node)
        node = self.filter("--input", ".payload.missing", "--condition", "true")
        wait(lambda: self.call(1,"graph.list")["nodes"][0])
        self.call(1,"graph.emit",output="result",payload={"text":"error"})
        node.wait(timeout=10)
        self.assertNotEqual(node.returncode,0)
        pending = self.inbox(3)
        self.assertEqual(len(pending),1)
        self.assertEqual(pending[0]["progress"]["status"],"failed")
        self.assertEqual(self.inbox(4),[])
        node = self.filter("--condition","true","--once")
        node.wait(timeout=10)
        self.assertEqual(node.returncode,0)
        self.assertEqual(self.inbox(4)[0]["text"],"error")
        self.assertEqual(self.inbox(3),[])
        # Switch the source to built-in Codex Turn completion notifications.
        path = self.folder / "session.jsonl"
        path.write_text('{"custom":"retain file path"}\n')
        self.call(1,"agent.event",provider="codex",event="SessionStart",session_id="codex-session",transcript_path=str(path))
        self.call(1,"graph.connect",**{"from":"%1","from_port":"turn_completed","to":"%3","to_port":"in"})
        self.call(1,"agent.event",provider="codex",event="Stop",text="finished")
        node = self.filter("--condition","true","--once")
        node.wait(timeout=10)
        self.assertEqual(node.returncode,0)
        event = self.inbox(4)[-1]
        self.assertNotIn("session", event)
        self.assertNotIn("checkpoint", event)
        self.assertEqual(event["sessions"][0]["path"],str(path))
        self.assertEqual(event["sessions"][0]["checkpoint"]["byte_offset"],path.stat().st_size)
        self.assertEqual(event["kind"],"turn.completed")
        self.assertEqual(event["type"],"message")

    def test_empty_transform_is_explicit_skip(self):
        node = self.filter("--condition","true","--transform","empty","--once")
        wait(self.manifest)
        self.connect()
        emitted = self.call(1,"graph.emit",output="result",payload=[1,2,3])
        node.wait(timeout=10)
        self.assertEqual(node.returncode,0)
        self.assertEqual(self.inbox(2),[])
        self.assertEqual(self.inbox(4),[])
        self.assertEqual(self.inbox(3),[])
        self.assertTrue(any(r["event_id"] == emitted["events"][0]["event_id"] and r["status"] == "skipped" for r in self.call(1,"graph.list")["receipts"]))

    def test_real_terminal_form_validates_edits_and_restores_terminal(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH",32,110,0,0))
        before = termios.tcgetattr(slave)
        screen = bytearray()
        terminal_screen = pyte.Screen(110,32)
        stream = pyte.ByteStream(terminal_screen)
        def drain():
            while select.select([master],[],[],0)[0]:
                chunk = os.read(master,65536)
                screen.extend(chunk)
                stream.feed(chunk)
            return "\n".join(terminal_screen.display)
        try:
            node = self.filter(stdin=slave,stdout=slave,stderr=slave,env={"TERM":"xterm-256color"})
            wait(self.manifest)
            self.connect()
            self.call(1,"graph.emit",output="result",payload={"text":"error in build", "details": list(range(40))})
            wait(lambda: "Condition" in drain())
            # SGR mouse: click the condition field (column 2, row 10).
            self.assertIn(b"\x1b[?1006h", screen)
            os.write(master,b"\x1b[<0;2;10M\x1b[<0;2;10m(")
            wait(lambda: "Paused" in drain())
            os.write(master,b"\x12")  # Ctrl+R must no longer apply.
            time.sleep(.2)
            self.assertNotIn("invalid jq", drain())
            self.assertEqual(self.inbox(4), [])
            os.write(master,b"\x1b[13;5u")  # Ctrl+Enter applies.
            wait(lambda:"invalid jq" in drain())
            self.assertEqual(len(self.inbox(3)),1)
            self.assertEqual(self.inbox(4),[])
            os.write(master,b'\x7fcontains("error")\x1b[13;5u')
            wait(lambda: (drain(), self.inbox(4))[1])
            self.assertEqual(self.inbox(4)[0]["text"],"error in build")
            # Drag across the name, replace it, then click in the middle.
            os.write(master,b"\x1b[<0;2;4M\x1b[<32;8;4M\x1b[<0;8;4mMouse\x1b[13;5u")
            wait(lambda: (drain(), self.manifest())[1]["name"] == "Mouse")
            os.write(master,b"\x1b[<0;4;4M\x1b[<0;4;4m!\x1b[13;5u")
            wait(lambda: (drain(), self.manifest())[1]["name"] == "Mo!use")
            # Wheel over the event pane changes the preview; wheel back restores it.
            rows = drain().splitlines()
            event_row = next(i for i, line in enumerate(rows) if "Latest incoming event" in line) + 2
            original_preview = rows[event_row:]
            os.write(master, f"\x1b[<65;10;{event_row + 1}M".encode())
            wait(lambda: drain().splitlines()[event_row:] != original_preview)
            os.write(master, f"\x1b[<64;10;{event_row + 1}M".encode())
            wait(lambda: drain().splitlines()[event_row:] == original_preview)
            os.write(master,b"\x03")
            wait(lambda:(drain(),node.poll())[1] is not None)
            self.assertEqual(node.returncode,0)
            self.assertEqual(termios.tcgetattr(slave),before)
            self.assertIn(b"\x1b[?1049l",screen)
            self.assertIn(b"\x1b[?1006l",screen)
        finally:
            (Path("/tmp/filter-form-screen.ansi")).write_bytes(screen)
            if 'node' in locals(): stop(node)
            os.close(master)
            os.close(slave)


if __name__ == "__main__": unittest.main()
