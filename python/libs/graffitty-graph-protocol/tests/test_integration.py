"""Opt-in: both SDKs against the real Rust graph through the existing UI fixture.

Build gft, graph_fixture and the Rust uppercase example first, then:
GRAFFITTY_SDK_INTEGRATION=1 uv run --directory python/libs/graffitty-graph-protocol pytest tests/test_integration.py
"""
import asyncio
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

import pytest

from graffitty_graph_protocol import Client, InputPort, Manifest, Output, Session

ROOT = Path(__file__).resolve().parents[4]
pytestmark = pytest.mark.skipif(os.environ.get("GRAFFITTY_SDK_INTEGRATION") != "1", reason="Requires built Graffitty/Godot fixtures")


def wait(check, processes):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert all(p.poll() is None for p in processes), "A fixture/node exited; inspect its test log"
        if result := check():
            return result
        time.sleep(.03)
    raise AssertionError("Timed out waiting for graph delivery")


async def check_manifest_and_session_parity(endpoint):
    cases = json.loads((ROOT / "tests/fixtures/graph-manifests.json").read_text())["valid"]
    async with Session(Client(endpoint, "5")) as source, Session(Client(endpoint, "4"), resume_inbox=False) as receiver:
        for case in cases:
            await source.register(Manifest.model_validate(case["manifest"]))
            # Compare the SDK serialization to the same declaration normalized
            # directly by the host, including icons, defaults and opaque metadata.
            await receiver.call("agent.register", case["manifest"])
            snapshot = await source.call("graph.list", {})
            manifests = {n["node"]: n.get("manifest") for n in snapshot["nodes"]}
            assert manifests["%5"] == manifests["%4"], case["case"]
        await source.register(Manifest.model_validate(cases[1]["manifest"]))
        await receiver.register(Manifest(inputs=[InputPort(id="in")], outputs=[]))
        for port, read, send, completed in [("send", False, True, False), ("read", True, False, False), ("done", True, False, True)]:
            edge = await source.call("graph.connect", {"from": "%5", "to": "%4", "from_port": port, "to_port": "in"})
            assert (edge["read"], edge["send"], edge["turn_completed"]) == (read, send, completed)
        await source.emit(Output(port="send", text="hello", payload={"ok": True}))
        events = await receiver.take()
        assert len(events) == 1 and events[0].payload == {"ok": True}
        await receiver.ack(events[0].event_id)
        await source.event("Stop", {"text": "finished", "completion_id": "sdk-turn-1"})
        events = await receiver.take()
        assert len(events) == 1 and events[0].type == "turn.completed" and events[0].source_port == "done"
        await receiver.ack(events[0].event_id)


@pytest.mark.parametrize("language", ["python", "rust"])
def test_real_graph_round_trip_and_lifecycle(tmp_path, language):
    # macOS Unix socket paths must fit sun_path; pytest's default path is longer.
    scratch = tempfile.TemporaryDirectory(prefix="gft-sdk-", dir="/tmp")
    logs = tmp_path
    tmp_path = Path(scratch.name)
    processes = []
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    env["XDG_CONFIG_HOME"] = str(tmp_path / "config")
    def start(command, **extra):
        log = (logs / f"process-{len(processes)}.log").open("w")
        try:
            process = subprocess.Popen(command, env={**env, **extra}, stdout=log, stderr=log)
        finally:
            log.close()
        processes.append(process)
        return process
    try:
        host = start(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                      "--script", "tests/jev_node_host.gd"], JEV_TEST_DIRECTORY=str(tmp_path))
        wait(lambda: (tmp_path / "ready.json").exists(), processes)
        endpoint = json.loads((tmp_path / "ready.json").read_text())["socket"]
        def rpc(token, method, **params):
            with socket.socket(socket.AF_UNIX) as peer:
                peer.settimeout(5)
                peer.connect(endpoint)
                request = dict(id=str(uuid4()), version=1, token=str(token), method=method, params=params)
                peer.sendall((json.dumps(request) + "\n").encode())
                reply = json.loads(peer.makefile("rb").readline())
                assert reply["id"] == request["id"] and "error" not in reply, reply
                return reply["result"]
        command = ([sys.executable, str(ROOT / "examples/uppercase-node/node.py")] if language == "python"
                   else [str(ROOT / "target/debug/examples/uppercase")])
        node = start(command, GRAFFITTY_SOCKET=endpoint, GRAFFITTY_TOKEN="3")
        def manifest():
            return next((n.get("manifest") for n in rpc(1, "graph.list")["nodes"]
                         if n["node"] == "%3" and n.get("manifest", {}).get("name") == "Uppercase"), None)
        declaration = wait(manifest, processes)
        assert declaration["icon"] == {"text": "Aa", "font": ""}
        assert declaration["inputs"][0]["icon"] == {"text": "↓", "font": ""}
        assert declaration["outputs"][0]["icon"] == {"text": "✓", "font": ""}
        assert declaration["outputs"][0]["line_style"] == "solid"
        assert declaration["outputs"][0]["mode"] == "send"
        registered = next(n for n in rpc(1, "graph.list")["nodes"] if n["node"] == "%3")
        assert registered["kind"] == "custom"
        assert registered["transport"] == "inbox"
        assert "provider" not in registered and "session_id" not in registered
        transcript = tmp_path / "session.jsonl"
        transcript.write_text('{"type":"assistant","message":{"content":"hello graph"}}\n')
        rpc(1, "agent.event", provider="claude", event="SessionStart", session_id="source-session", transcript_path=str(transcript))
        rpc(1, "graph.connect", **{"from": "%1", "from_port": "turn_completed", "to": "%3", "to_port": "in"})
        rpc(3, "graph.connect", **{"from": "%3", "from_port": "out", "to": "%4", "to_port": "in"})
        rpc(1, "agent.event", provider="claude", event="Stop", text="hello graph")
        events = wait(lambda: rpc(4, "graph.take")["events"], processes)
        assert len(events) == 1
        event = events[0]
        assert event["text"] == "HELLO GRAPH"
        assert event["sessions"][0]["path"] == str(transcript)
        assert event["sessions"][0]["checkpoint"]["byte_offset"] == transcript.stat().st_size
        assert event["origin"]["source"] == "%1" and event["caused_by"] == event["origin"]["event_id"]
        wait(lambda: not rpc(3, "graph.take")["events"], processes)
        rpc(4, "graph.ack", event_id=event["event_id"], status="delivered")
        # The same SDK forwards a Manual Prompt-style source without a session.
        # Reusing the agent pane also checks stale transcript metadata is cleared.
        rpc(1, "agent.event", kind="custom", event="SessionStart", pid=200)
        rpc(1, "agent.register", name="Manual Prompt", inputs=[], outputs=[dict(id="out")])
        rpc(1, "graph.connect", **{"from":"%1", "from_port":"out", "to":"%3", "to_port":"in"})
        rpc(1, "graph.emit", output="out", text="manual prompt", payload={"text":"manual prompt"})
        forwarded = wait(lambda: rpc(4, "graph.take")["events"], processes)[0]
        assert forwarded["text"] == "MANUAL PROMPT" and forwarded["sessions"] == []
        assert forwarded["origin"]["source"] == "%1"
        wait(lambda: not rpc(3, "graph.take")["events"], processes)
        node.send_signal(signal.SIGTERM)
        assert node.wait(timeout=8) == 0
        assert next(n for n in rpc(1, "graph.list")["nodes"] if n["node"] == "%3")["status"] == "offline"
        if language == "python":
            asyncio.run(check_manifest_and_session_parity(endpoint))
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        scratch.cleanup()
