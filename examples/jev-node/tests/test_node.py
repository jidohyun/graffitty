import asyncio
import json
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

import common
from common import Event, JudgeNode, Settings, last_messages
from fastapi_node import create_app


def record(provider, text, role="assistant"):
    if provider == "codex":
        return {"type": "response_item", "payload": {"type": "message", "role": role,
                "content": [{"type": "output_text", "text": text}]}}
    return {"type": role, "message": {"role": role, "content": [{"type": "text", "text": text}]}}


def event_file(tmp_path, provider="codex"):
    path = tmp_path / "session.jsonl"
    lines = [record(provider, f"message {i} 한글", "user" if i % 2 == 0 else "assistant")
             for i in range(15)]
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in lines))
    checkpoint = path.stat().st_size
    # Later data must never leak into this event's context.
    with path.open("a") as file:
        file.write(json.dumps(record(provider, "FUTURE")) + "\n")
    return {"event_id": "input-1", "run_id": "run-1", "type": "turn.completed",
            "source": "%1", "text": "Approved.",
            "sessions": [{"provider": provider, "id": "session-1", "path": str(path),
                          "checkpoint": {"byte_offset": checkpoint}}]}


class FakeHost:
    token = "test-token"

    def __init__(self, events=(), status="queued", fail_ack=False):
        self.events = list(events)
        self.calls = []
        self.status = status
        self.fail_ack = fail_ack

    async def call(self, method, params):
        self.calls.append((method, params))
        if method == "graph.take":
            return {"events": self.events.copy()}
        if method == "graph.forward":
            return {"status": self.status, "events": [{"event_id": "out-1"}]}
        if method == "graph.ack":
            if self.fail_ack:
                self.fail_ack = False
                raise OSError("lost acknowledgment")
            self.events = [e for e in self.events if e["event_id"] != params["event_id"]]
        return {"ok": True}


@pytest.fixture(autouse=True)
def api_key(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "fixture-key")


@pytest.mark.parametrize("provider", ["codex", "claude"])
def test_history_checkpoint_and_last_ten(tmp_path, provider):
    raw = event_file(tmp_path, provider)
    messages = last_messages(Event.model_validate(raw))
    assert len(messages) == 10
    assert messages[0]["text"] == "message 5 한글"
    assert messages[-1]["text"] == "message 14 한글"


@pytest.mark.parametrize("provider", ["codex", "claude"])
def test_nonconversation_records_and_partial_tail(tmp_path, provider):
    raw = event_file(tmp_path, provider)
    path = Path(raw["sessions"][0]["path"])
    records = [record(provider, "one")]
    if provider == "codex":
        records += [{"type": "event_msg", "payload": {"type": "agent_message", "message": "duplicate"}},
                    {"type": "response_item", "payload": {"type": "function_call_output", "output": "tool"}}]
    else:
        sidechain = record(provider, "sidechain")
        sidechain["isSidechain"] = True
        records += [sidechain, {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "tool text"}]}}]
    path.write_bytes(("".join(json.dumps(r) + "\n" for r in records) + '{"unfinished":').encode())
    raw["sessions"][0]["checkpoint"]["byte_offset"] = path.stat().st_size
    assert last_messages(Event.model_validate(raw)) == [{"role": "assistant", "text": "one"}]


def test_reverse_read_crosses_block_boundary_and_rejects_truncation(tmp_path):
    raw = event_file(tmp_path)
    path = Path(raw["sessions"][0]["path"])
    path.write_text(json.dumps(record("codex", "한" * 40000)) + "\n")
    raw["sessions"][0]["checkpoint"]["byte_offset"] = path.stat().st_size
    assert last_messages(Event.model_validate(raw))[0]["text"] == "한" * 40000
    path.write_text("")
    with pytest.raises(ValueError, match="truncated"):
        last_messages(Event.model_validate(raw))


@pytest.mark.parametrize("probability,expected", [(0.9, "True"), (0.1, "False"), (0.5, "True")])
def test_boolean_routing_preserves_message_run_and_deduplicates(tmp_path, probability, expected):
    raw = event_file(tmp_path)
    requests = []
    def respond(request):
        requests.append(json.loads(request.content))
        assert str(request.url) == common.DECISIONS_URL
        assert request.headers["authorization"] == "Bearer fixture-key"
        return httpx.Response(200, json={"answers": {"route": {"type": "noul", "noul": probability}}})
    async def run():
        host = FakeHost()
        settings = Settings(question="Approved?")
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            node = JudgeNode(settings, host, client)
            first, second = await asyncio.gather(node.process(raw), node.process(raw))
            assert first == second
            assert first["status"] == "delivered"
            assert first["output"] == expected
        assert host.calls == [("graph.forward", {"output": expected, "event_id": raw["event_id"]})]
    asyncio.run(run())
    assert len(requests) == 1
    assert requests[0]["model"] == "typesafe/jev-1.13"
    assert requests[0]["questions"]["route"]["type"] == "noul"
    assert len(requests[0]["state"]["recent_messages"]) == 10
    assert "FUTURE" not in json.dumps(requests[0])


def test_choice_routing(tmp_path):
    raw = event_file(tmp_path, "claude")
    settings = Settings(question="Review?", options={"approved": "Explicit approval", "revise": "Fixes needed"})
    def respond(request):
        assert json.loads(request.content)["questions"]["route"]["criteria"] == settings.options
        return httpx.Response(200, json={"answers": {"route": {"type": "choice", "choice": "revise"}}})
    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            host = FakeHost()
            receipt = await JudgeNode(settings, host, client).process(raw)
            assert receipt["output"] == "revise"
            assert host.calls[0][1]["output"] == "revise"
    asyncio.run(run())


def test_missing_send_edge_explains_failure_after_successful_judgment(tmp_path):
    class DeniedHost(FakeHost):
        async def call(self, method, params):
            raise common.HostError(method, {"code": "connection_changed",
                "message": "Output True has no active matching Send connections", "adjacent": {"private": "omit"}})
    async def run():
        settings = Settings(question="Approved?")
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(
            200, json={"answers": {"route": {"type": "noul", "noul": 0.9}}}))) as client:
            receipt = await JudgeNode(settings, DeniedHost(), client).process(event_file(tmp_path))
        assert receipt["status"] == "failed"
        assert receipt["stage"] == "forward_message"
        assert receipt["output"] == "True"
        assert "no active matching Send connections" in receipt["detail"]
        assert "private" not in json.dumps(receipt)
    asyncio.run(run())


def test_validation_diagnostic_excludes_input_content():
    with pytest.raises(common.ValidationError) as caught:
        Event.model_validate({"text": "PRIVATE SESSION CONTENT"})
    detail = common.error_explanation(caught.value)
    assert "sessions: missing" in detail
    assert "PRIVATE" not in detail


@pytest.mark.parametrize("failure", ["api", "invalid", "unknown", "no_read", "provider", "filtered", "oversized"])
def test_failures_never_route_false(tmp_path, failure):
    raw = event_file(tmp_path)
    if failure == "no_read":
        del raw["sessions"][0]["path"]
    if failure == "provider":
        raw["sessions"][0]["provider"] = "other"
    if failure == "oversized":
        raw["text"] = "x" * (common.MAX_CONTEXT + 1)
    def respond(request):
        answer = {"type": "noul", "noul": 0.9}
        if failure == "invalid":
            answer["noul"] = 2
        if failure == "unknown":
            answer = {"type": "choice", "choice": "other"}
        return httpx.Response(503 if failure == "api" else 200, json={"answers": {"route": answer}})
    async def run():
        host = FakeHost(status="filtered" if failure == "filtered" else "queued")
        settings = Settings(question="Approved?")
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            receipt = await JudgeNode(settings, host, client).process(raw)
        assert receipt["status"] == "failed"
        assert len(host.calls) == (1 if failure == "filtered" else 0)
    asyncio.run(run())


def test_fastapi_lifecycle_authorization_and_ack_retry(tmp_path):
    raw = event_file(tmp_path)
    host = FakeHost([raw], fail_ack=True)
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(
        200, json={"answers": {"route": {"type": "noul", "noul": 0.8}}})))
    settings = Settings(question="Approved?")
    app = create_app(settings, host, client)
    with TestClient(app) as http:
        headers = {"Authorization": "Bearer test-token"}
        assert http.get("/manifest").status_code == 401
        assert http.get("/manifest", headers=headers).json()["outputs"][0]["id"] == "True"
        # The automatic pump attempts the first ack; the HTTP request retries it.
        for _ in range(3):
            result = http.post("/events/input-1", headers=headers)
            if not host.events:
                break
        assert result.json()["status"] == "delivered"
        assert not host.events
        assert http.post("/events/unregistered", headers=headers).status_code == 404
    assert sum(method == "graph.forward" for method, _ in host.calls) == 1
    assert host.calls[0][1]["event"] == "SessionStart"
    assert host.calls[-1][1]["event"] == "SessionEnd"


def test_node_identity_and_output_symbols():
    settings = Settings(question="Approved?", name="Reviewer", icon="⚖",
                        output_icons={"True": {"text": "✓", "font": "Symbols Nerd Font Mono"},
                                      "False": {"svg": '<svg viewBox="0 0 24 24"></svg>'}})
    node = JudgeNode(settings, FakeHost(), None)
    manifest = node.manifest()
    assert manifest["name"] == "Reviewer"
    assert manifest["icon"] == "⚖"
    assert manifest["outputs"][0]["icon"]["font"] == "Symbols Nerd Font Mono"
    assert "svg" in manifest["outputs"][1]["icon"]


def test_settings_file_environment_and_cli_precedence(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"question":"From file?", "name":"File name", "threshold":0.7}))
    monkeypatch.setenv("GRAFFITTY_NODE_CONFIG", str(path))
    monkeypatch.setenv("GRAFFITTY_NODE_SETTINGS", json.dumps({"name":"Environment name", "threshold":0.8}))
    settings = Settings.load(overrides={"name":"CLI name"})
    assert settings.question == "From file?"
    assert settings.name == "CLI name"
    assert settings.threshold == 0.8
    monkeypatch.setenv("GRAFFITTY_NODE_SETTINGS", "[]")
    with pytest.raises(ValueError, match="JSON object"):
        Settings.load()


def test_interactive_question_uses_tty_not_protocol_stdin(tmp_path):
    import fcntl
    import os
    import pty
    import select
    import signal
    import subprocess
    import sys
    import termios
    import time

    master, slave = pty.openpty()
    code = (
        "import os,fcntl,termios,sys,json; "
        f"os.setsid(); fcntl.ioctl({slave},termios.TIOCSCTTY,0); "
        "from common import Settings; "
        "settings,_=Settings.from_cli(); "
        "print(json.dumps({'question':settings.question,'protocol':sys.stdin.readline().strip()}),flush=True)"
    )
    env = {k:v for k,v in os.environ.items() if k not in ("GRAFFITTY_NODE_CONFIG","GRAFFITTY_NODE_SETTINGS","JEV_CONFIG")}
    env.update(TERM="xterm-256color", PROMPT_TOOLKIT_NO_CPR="1")
    process = subprocess.Popen([sys.executable,"-c",code], cwd=Path(common.__file__).parent,
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(slave,),env=env)
    try:
        process.stdin.write(b"PROTOCOL EVENT\n")
        process.stdin.flush()
        capture = bytearray()
        deadline = time.monotonic()+8
        while b"Question:" not in capture and time.monotonic()<deadline:
            if select.select([master],[],[],0.1)[0]: capture.extend(os.read(master,65536))
            if process.poll() is not None: break
        assert b"Question:" in capture, (capture, process.stderr.read() if process.poll() is not None else b"still running")
        os.write(master,b"Is the work complete?\r")
        # Drain terminal responses while the prompt restores terminal state.
        while process.poll() is None and time.monotonic()<deadline:
            if select.select([master],[],[],0.1)[0]: capture.extend(os.read(master,65536))
        stdout,stderr=process.communicate(timeout=3)
        assert process.returncode == 0, stderr.decode()
        assert json.loads(stdout) == {"question":"Is the work complete?","protocol":"PROTOCOL EVENT"}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        os.close(master)
        os.close(slave)


def test_multiple_sessions_keep_their_own_checkpoint_and_identity(tmp_path):
    combined = None
    for provider in ("codex", "claude"):
        folder = tmp_path / provider
        folder.mkdir()
        raw = event_file(folder, provider)
        raw["sessions"][0]["id"] = provider + "-session"
        if combined is None:
            combined = raw
        else:
            combined["sessions"].extend(raw["sessions"])
    messages = last_messages(Event.model_validate(combined))
    assert len(messages) == 20
    assert {m["session_id"] for m in messages} == {"codex-session", "claude-session"}
    assert all("FUTURE" not in m["text"] for m in messages)
    assert [m["provider"] for m in messages] == ["codex"] * 10 + ["claude"] * 10
