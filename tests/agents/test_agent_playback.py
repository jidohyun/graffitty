# /// script
# requires-python = ">=3.11"
# dependencies = ["websocket-client"]
# ///
"""Real private server, CLI TUIs, PTYs, graph queues, and provider transcripts.

Run after cargo build -p graffitty: uv run tests/agents/test_agent_playback.py
No provider binaries or model APIs are used.
"""
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_server import PrivateServer
from test_session_transfer import Peer


def wait(check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.03)
    raise AssertionError("Timed out waiting for playback")


@unittest.skipUnless(os.name == "posix", "Private Unix PTY fixture")
class AgentPlaybackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gft-playback-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(self.folder / kind.lower())
        self.owner = self.enterContext(PrivateServer(env, self.folder, "/bin/sh"))
        self.peer = Peer(json.loads(self.owner.descriptor.read_text())["local"], "playback", new=True)
        self.addCleanup(self.peer.socket.close)
        self.contexts = {}
        self.first = self.peer.topology["panes"][0]["id"]
        self.context(self.first)

    def context(self, pane):
        path = self.folder / f"pane-{pane}.json"
        code = "import json,os;json.dump({k:os.environ[k] for k in ['GRAFFITTY_SOCKET','GRAFFITTY_TOKEN']},open(" + repr(str(path)) + ",'w'))"
        self.peer.action("text", pane, text="umask 077; " + shlex.join([sys.executable, "-c", code]) + "\n")
        wait(lambda: path.exists() and path.stat().st_size)
        self.contexts[pane] = json.loads(path.read_text())

    def pane(self):
        pane = self.peer.action("create", self.first, kind="pane")["created"]
        self.context(pane)
        return pane

    def rpc(self, pane, method, **params):
        context = self.contexts[pane]
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(5)
            stream.connect(context["GRAFFITTY_SOCKET"].removeprefix("ipc://"))
            request = dict(id=str(uuid.uuid4()), version=1, token=context["GRAFFITTY_TOKEN"], method=method, params=params)
            stream.sendall((json.dumps(request) + "\n").encode())
            with stream.makefile("rb") as reader:
                reply = json.loads(reader.readline())
        self.assertNotIn("error", reply)
        return reply["result"]

    def node(self, pane):
        return next(n for n in self.rpc(self.first, "graph.list")["nodes"] if n["node"] == f"%{pane}")

    def start(self, pane, provider, config):
        path = self.folder / f"scenario-{pane}.json"
        path.write_text(json.dumps(config))
        self.peer.action("text", pane, text=shlex.join([str(self.owner.binary), "dev", provider + "-mock", "--config", str(path)]) + "\n")
        wait(lambda: self.node(pane).get("transport") == "inbox")

    def connect(self, source, output, target):
        return self.rpc(self.first, "graph.connect", **{"from": f"%{source}", "from_port": output, "to": f"%{target}", "to_port": "in"})

    def text(self, pane):
        return self.rpc(pane, "terminal.get_text")["text"]

    def test_prompt_editing_matches_manual_and_both_mock_providers(self):
        sink = self.pane()
        self.rpc(sink, "agent.event", provider="adapter", event="SessionStart")
        self.rpc(sink, "agent.register", name="Prompts", inputs=[{"id": "in"}], outputs=[])
        count = 0
        for provider in ("manual", "codex", "claude"):
            with self.subTest(provider=provider):
                pane = self.pane()
                if provider == "manual":
                    self.peer.action("text", pane, text=shlex.join([str(self.owner.binary), "node", "manual-prompt"]) + "\n")
                    wait(lambda: self.node(pane).get("manifest", {}).get("name") == "Manual Prompt")
                    wait(lambda: "[ Send ]" in self.text(pane))
                else:
                    self.start(pane, provider, {"think_ms": 0, "char_ms": 0, "response": "{prompt}"})
                    wait(lambda: ("OpenAI Codex" if provider == "codex" else "Claude Code") in self.text(pane))
                self.connect(pane, "out" if provider == "manual" else "turn_completed", sink)

                def send(text):
                    self.peer.action("text", pane, text=text)

                def emitted(expected):
                    nonlocal count
                    count += 1
                    def received():
                        events = self.rpc(sink, "graph.take")["events"]
                        return events if len(events) >= count else None
                    events = wait(received)
                    self.assertEqual(len(events), count)
                    self.assertEqual(events[-1]["text"], expected)

                send("discard me")
                wait(lambda: "discard me" in self.text(pane))
                send("\x15keep first second\x17")  # Ctrl+U, then Ctrl+W.
                wait(lambda: "keep first" in self.text(pane) and "second" not in self.text(pane))
                send("\x01" + "\x1b[C" * 5 + "\x0bvalue")  # Ctrl+A, right, Ctrl+K.
                send("\x1b[13;2uline two\x1b[13;3u끝")  # Shift+Enter and Alt+Enter.
                wait(lambda: "line two" in self.text(pane) and "끝" in self.text(pane))
                self.assertEqual(len(self.rpc(sink, "graph.take")["events"]), count)
                send("\r")
                emitted("keep value\nline two\n끝")
                send("scratch\x01\x1b[A\r")  # Recall and resubmit the multiline prompt.
                emitted("keep value\nline two\n끝")
                send("draft\x01\x1b[A\x1b[B\x05!\r")  # Recall, restore draft, append.
                emitted("draft!")

                long_prompt = "0123456789 " * 20 + "mouse_target suffix"
                send("\x1b[200~" + long_prompt + "\x1b[201~")
                wait(lambda: "mouse_target" in self.text(pane) and "suffix" in self.text(pane))
                self.assertGreater(sum("0123456789" in line for line in self.text(pane).splitlines()), 1)

                def target():
                    lines = self.text(pane).splitlines()
                    y = next(i for i, line in enumerate(lines) if "mouse_target" in line)
                    return lines[y].index("mouse_target") + 1, y + 1

                x, y = target()
                send(f"\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m\x15")
                wait(lambda: "0123456789" not in self.text(pane))
                x, y = target()
                send(f"\x1b[<0;{x};{y}M\x1b[<32;{x + 12};{y}M\x1b[<0;{x + 12};{y}mclicked\r")
                emitted("clicked suffix")
                send("\x03")
                wait(lambda: self.node(pane)["status"] == "offline")

    def test_real_queue_chain_titles_read_and_no_native_delivery(self):
        codex, claude, sink = self.first, self.pane(), self.pane()
        self.start(codex, "codex", {"char_ms": 0, "think_ms": 400, "response": "The dashboard is ready.",
            "completion": {"elapsed_ms": 1120000, "completed_at": "11:13 PM"}})
        self.start(claude, "claude", {"char_ms": 0,
            "completion": {"elapsed_ms": 1080000, "completed_at": "3:03 PM"}, "turns": [{"steps": [
            {"type": "think", "ms": 600},
            {"type": "edit", "path": "app.tsx", "before": "const ready = false;\n",
             "after": "const ready = true;\nconst accessible = true;\nconst verified = true;\n",
             "line": 42, "ms": 100},
            {"type": "tool", "name": "Read", "input": "app.tsx", "output": "Read 42 lines", "ms": 500}],
            "response": "Reviewed. All checks pass."}]})
        self.rpc(sink, "agent.event", provider="adapter", event="SessionStart")
        self.rpc(sink, "agent.register", name="Result", inputs=[{"id": "in"}], outputs=[])
        self.connect(codex, "turn_completed", claude)
        self.connect(claude, "turn_completed", sink)
        wait(lambda: "OpenAI Codex" in self.text(codex))
        wait(lambda: "Claude Code" in self.text(claude))
        self.assertIn("Opus 5.5", self.text(claude))
        self.peer.action("text", codex, text="Build a dashboard\r")
        wait(lambda: self.node(codex)["status"] == "busy")
        self.assertEqual(self.node(codex)["manifest"]["name"], "Build a dashboard")
        wait(lambda: self.node(claude)["status"] == "busy")
        # Lifecycle RPCs and PTY frames travel independently; wait for both.
        # The mock shows the received message as Claude Code does, followed by
        # its long peer notice. In this narrow pane the notice pushes the
        # message itself off the screen, so wait for the notice's last words;
        # the transcript below proves which message arrived.
        wait(lambda: "permission laundering." in self.text(claude))
        events = wait(lambda: self.rpc(sink, "graph.take")["events"])
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["text"], "Reviewed. All checks pass.")
        wait(lambda: "Worked for 18m 40s • 11:13 PM" in self.text(codex))
        wait(lambda: "✻ Cooked for 18m 0s · done 3:03 PM" in self.text(claude))
        self.assertEqual(events[0]["sessions"][0]["provider"], "claude")
        transcript = Path(events[0]["sessions"][0]["path"])
        messages = [json.loads(line) for line in transcript.read_text().splitlines()]
        incoming = messages[0]["message"]["content"][0]["text"]
        self.assertIn("\nThe dashboard is ready.\nPayload (JSON): ", incoming)
        envelope = json.loads(incoming.split("\nPayload (JSON): ", 1)[1])
        self.assertEqual(envelope["type"], "turn.completed")
        self.assertEqual(envelope["source"], f"%{codex}")
        self.assertEqual(envelope["run_id"], events[0]["run_id"])
        self.assertEqual(envelope["sessions"][0]["provider"], "codex")
        source_transcript = Path(envelope["sessions"][0]["path"])
        self.assertTrue(source_transcript.is_file())
        self.assertGreater(envelope["sessions"][0]["checkpoint"]["byte_offset"], 0)
        self.assertIn("The dashboard is ready.", source_transcript.read_text())
        self.assertEqual(messages[-1]["message"]["content"][0]["text"], "Reviewed. All checks pass.")
        self.assertEqual(self.node(claude)["manifest"]["name"], "The dashboard is ready.")
        titles = {p["id"]: p["title"] for p in self.peer.sync()["panes"]}
        self.assertEqual(titles[codex], "Build a dashboard")
        self.assertEqual(titles[claude], "The dashboard is ready.")
        rows = self.rpc(codex, "graph.queue")["events"]
        self.assertEqual(len({r["run_id"] for r in rows}), 1)
        self.assertTrue(all(r["status"] != "queued in Codex" for r in rows))
        self.assertIn("Read(app.tsx)", self.text(claude))
        self.assertIn("Update(app.tsx)", self.text(claude))
        self.assertNotIn("const verified", self.text(claude))
        self.peer.action("text", claude, text="\x14")  # Ctrl+T expands retained edits.
        wait(lambda: "const verified" in self.text(claude))
        self.peer.action("text", claude, text="\x14")
        wait(lambda: "const verified" not in self.text(claude))
        # Owner process scans run every two seconds: these must not erase the providers.
        time.sleep(2.2)
        self.assertEqual(self.node(codex)["provider"], "codex")
        self.assertEqual(self.node(claude)["provider"], "claude")
        for pane in (codex, claude):
            self.assertNotIn("mock", self.text(pane).lower())
            self.assertNotIn("demo", self.text(pane).lower())
            self.peer.action("text", pane, text="\x03")
            wait(lambda: self.node(pane)["status"] == "offline")

    def test_both_providers_record_session_references_in_received_completion(self):
        for source_provider, receiver_provider in [("codex", "claude"), ("claude", "codex")]:
            with self.subTest(receiver=receiver_provider):
                source, receiver = self.pane(), self.pane()
                self.start(source, source_provider, {"think_ms":0, "char_ms":0, "response":"Implementation complete."})
                self.start(receiver, receiver_provider, {"think_ms":0, "char_ms":0, "response":"Reviewed."})
                self.connect(source, "turn_completed", receiver)
                receiver_path = self.folder / "state/graffitty/recording-sessions" / (self.node(receiver)["session_id"] + ".jsonl")
                self.peer.action("text", source, text="Implement the spec\r")
                def received():
                    for line in receiver_path.read_text().splitlines():
                        record = json.loads(line)
                        message = record.get("message", record.get("payload", {}))
                        if message.get("role") == "user":
                            for part in message.get("content", []):
                                if "\nPayload (JSON): " in part.get("text", ""):
                                    return json.loads(part["text"].split("\nPayload (JSON): ", 1)[1])
                event = wait(received)
                reference = event["sessions"][0]
                self.assertEqual(reference["provider"], source_provider)
                self.assertEqual(reference["id"], self.node(source)["session_id"])
                self.assertEqual(event["text"], "Implementation complete.")
                self.assertTrue(Path(reference["path"]).is_file())
                self.assertGreater(reference["checkpoint"]["byte_offset"], 0)

    def test_busy_queue_revocation_unicode_and_interrupt(self):
        source, agent, sink = self.first, self.pane(), self.pane()
        for pane in (source, sink):
            self.rpc(pane, "agent.event", provider="adapter", event="SessionStart")
            self.rpc(pane, "agent.register", name="Node", inputs=[{"id":"in"}], outputs=[{"id":"out"}])
        self.start(agent, "codex", {"think_ms": 800, "char_ms": 0, "response": "안녕하세요 {prompt}"})
        self.connect(source, "out", agent)
        self.connect(agent, "turn_completed", sink)
        self.rpc(source, "graph.emit", output="out", payload={"text": "첫 질문"})
        wait(lambda: self.node(agent)["status"] == "busy")
        self.rpc(source, "graph.emit", output="out", payload={"text": "remove this"})
        self.assertEqual(len(self.rpc(agent, "graph.take")["events"]), 1)
        self.rpc(source, "graph.disconnect", **{"from": f"%{source}", "to": f"%{agent}"})
        self.assertEqual(self.rpc(agent, "graph.take")["events"], [])
        events = wait(lambda: self.rpc(sink, "graph.take")["events"])
        self.assertEqual(events[0]["text"], "안녕하세요 첫 질문")
        self.assertEqual(self.node(agent)["title"], "첫 질문")
        self.peer.action("text", agent, text="interrupt me\r")
        wait(lambda: self.node(agent)["status"] == "busy")
        self.peer.action("text", agent, text="\x1b")
        wait(lambda: self.node(agent)["status"] == "idle")
        self.assertEqual(len(self.rpc(sink, "graph.take")["events"]), 1)
        # The idle event can arrive before the PTY's next rendered frame.
        wait(lambda: "Conversation interrupted" in self.text(agent))

    def test_headless_once_uses_cli_defaults_and_rejects_invalid_configuration(self):
        env = {k: v for k, v in self.owner.env.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
        for provider in ("codex", "claude"):
            result = subprocess.run([self.owner.binary, "dev", provider + "-mock", "--headless", "--once",
                "--prompt", "hello 한글", "--response", "Received {prompt}, turn {turn}", "--think-ms", "0", "--char-ms", "0"],
                env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Received hello 한글, turn 1", result.stdout)
            self.assertNotIn("mock", result.stdout.lower())
        invalid = self.folder / "invalid.json"
        invalid.write_text('{"think_ms": -1}')
        result = subprocess.run([self.owner.binary, "dev", "claude-mock", "--config", invalid],
            env=env, text=True, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)

    def test_real_tools_are_opt_in_and_report_actual_results_and_failure(self):
        env = {k: v for k, v in self.owner.env.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                marker = self.folder / f"executed-{provider}"
                config = self.folder / f"real-{provider}.json"
                code = "import pathlib,sys;pathlib.Path(sys.argv[1]).write_text(sys.argv[2]);print('actual stdout');print('actual stderr',file=sys.stderr)"
                scenario = {"char_ms": 0, "turns": [{"steps": [{"type": "tool",
                    "name": "exec_command" if provider == "codex" else "Bash",
                    "input": "run the configured command", "output": "invented output", "exit_code": 9,
                    "command": [sys.executable, "-c", code, str(marker), "{prompt}"], "ms": 0}],
                    "response": "Finished."}]}
                config.write_text(json.dumps(scenario))
                command = [self.owner.binary, "dev", provider + "-mock", "--config", config,
                           "--headless", "--once", "--prompt", "literal; not shell code"]
                dry = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(dry.returncode, 0, dry.stderr)
                self.assertFalse(marker.exists())
                actual = subprocess.run([*command, "--real-tool-calling"], env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertEqual(marker.read_text(), "{prompt}")
                self.assertIn("actual stdout", actual.stdout)
                self.assertIn("actual stderr", actual.stdout)
                self.assertIn("Exit code: 0", actual.stdout)
                self.assertNotIn("invented output", actual.stdout)
                scenario["real_tool_calling"] = True
                scenario["turns"][0]["steps"][0]["command"] = [sys.executable, "-c", "print('real failure');raise SystemExit(7)"]
                config.write_text(json.dumps(scenario))
                failed = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                self.assertIn("real failure", failed.stdout)
                self.assertIn("Command failed (exit 7)", failed.stdout)
                self.assertNotIn("Finished.", failed.stdout)

    def test_real_tool_uses_scoped_cli_and_interrupt_stops_child(self):
        pane = self.first
        marker = self.folder / "tool-child.pid"
        code = "import os,pathlib,time;pathlib.Path(" + repr(str(marker)) + ").write_text(str(os.getpid()));time.sleep(30)"
        self.start(pane, "codex", {"real_tool_calling": True, "char_ms": 0, "turns": [{"steps": [
            {"type": "tool", "name": "exec_command", "input": "gft graph list",
             "command": [str(self.owner.binary), "graph", "list"], "ms": 0},
            {"type": "tool", "name": "exec_command", "input": "long-running test",
             "command": ["/bin/sh", "-c", shlex.join([sys.executable, "-c", code]) + " & wait"], "ms": 0}],
             "response": "Should not complete."}]})
        self.peer.action("text", pane, text="Run the test\r")
        wait(lambda: marker.exists())
        child = int(marker.read_text())
        self.assertIn("gft graph list", self.text(pane))
        self.peer.action("text", pane, text="\x1b")
        wait(lambda: self.node(pane)["status"] == "idle")
        def stopped():
            try:
                os.kill(child, 0)
                return False
            except ProcessLookupError:
                return True
        wait(stopped)
        self.assertNotIn("Should not complete.", self.text(pane))


if __name__ == "__main__":
    unittest.main()
