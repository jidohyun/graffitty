import asyncio

import pytest
from pydantic import ValidationError

from graffitty_graph_protocol import Checkpoint, Event, InputPort, Node, Output, OutputPort, SessionReference

EVENT = dict(type="message", event_id="event-1", run_id="run-1", source="%1", target="%2",
             source_port="out", target_port="in", text="hello", sessions=[dict(provider="codex", id="s")])


class Host:
    def __init__(self, *, fail=None):
        self.calls = []
        self.fail = fail

    async def call(self, method, params):
        self.calls.append((method, params))
        if method == self.fail:
            raise RuntimeError("Connection removed")
        if method == "graph.take":
            return {"events": [EVENT]}
        return {"status": "queued"} if method == "graph.forward" else {"ok": True}


def test_registration_forward_ack_shutdown():
    async def check():
        host = Host()
        node = Node("Uppercase", inputs=["in"], outputs=["out"], client=host)

        @node.on("in")
        async def uppercase(message):
            node.stop()
            return Output(port="out", text=message.text.upper())

        await node.serve()
        methods = [m for m, p in host.calls]
        assert methods == ["agent.event", "agent.register", "graph.take", "graph.forward", "graph.ack", "agent.event"]
        assert host.calls[0][1]["resume_inbox"] is True
        assert host.calls[0][1]["kind"] == "custom"
        assert "provider" not in host.calls[0][1] and "session_id" not in host.calls[0][1]
        assert host.calls[1][1]["outputs"] == [dict(id="out", mode="send", line_style="solid")]
        assert host.calls[3][1] == dict(event_id="event-1", output="out", content={"text": "HELLO"})
        assert host.calls[-1][1]["event"] == "SessionEnd"
    asyncio.run(check())


@pytest.mark.parametrize("failure", ["handler", "graph.forward", "bad_output"])
def test_failure_retains_input_and_closes_lifecycle(failure):
    async def check():
        host = Host(fail=failure)
        node = Node("Fail", inputs=["in"], outputs=["out"], client=host)

        @node.on("in")
        def handler(message):
            if failure == "handler":
                raise ValueError("Application error")
            return [Output(port="out"), Output(port="typo")] if failure == "bad_output" else Output(port="out")

        with pytest.raises(ExceptionGroup):
            await node.serve()
        assert not any(m == "graph.ack" for m, p in host.calls)
        assert any(m == "graph.progress" and p["status"] == "failed" for m, p in host.calls)
        if failure == "bad_output":
            assert not any(m == "graph.forward" for m, p in host.calls)
        assert host.calls[-1][1]["event"] == "SessionEnd"
    asyncio.run(check())


def test_pydantic_validation_optional_access_and_preserving_fields():
    assert SessionReference(id="local-conversation", path="/tmp/session.jsonl").provider is None
    assert Event.model_validate({**EVENT, "sessions": []}).sessions == []
    assert Checkpoint(byte_offset=57.0).byte_offset == 57
    for offset in [True, -1, 1.5, float("nan"), float(2**53)]:
        with pytest.raises(ValidationError):
            Checkpoint(byte_offset=offset)
    event = Event.model_validate({**EVENT, "future_field": {"keep": True}})
    assert event.sessions[0].path is None
    assert event.model_dump()["future_field"] == {"keep": True}
    assert Output(port="out").overrides() == {}
    assert Output(port="out", payload=None).overrides() == {"payload": None}
    with pytest.raises(ValidationError):
        Output(port="out", run_id="forged")
    for kwargs in [dict(id="bad id"), dict(id="ok", line_style="dotted")]:
        with pytest.raises(ValidationError):
            OutputPort(**kwargs)
    with pytest.raises(ValidationError):
        Node("Duplicate", inputs=["in", "in"], outputs=[])
    with pytest.raises(ValidationError):
        InputPort(id="in", name="가" * 43)


def test_optional_integration_provider_does_not_create_a_session():
    async def check():
        host = Host()
        node = Node("Chat", inputs=["in"], outputs=[], client=host, provider="telegram")
        @node.on("in")
        async def consume(event):
            node.stop()
        await node.serve()
        assert host.calls[0][1]["provider"] == "telegram"
        assert "session_id" not in host.calls[0][1]
    asyncio.run(check())


def test_handlers_checked_before_registration():
    host = Host()
    node = Node("Missing", inputs=["in"], outputs=[], client=host)
    with pytest.raises(ValueError, match="Missing handlers"):
        asyncio.run(node.serve())
    assert host.calls == []
    with pytest.raises(ValueError, match="Unknown input"):
        node.on("typo")
    node.on("in")(lambda message: None)
    with pytest.raises(ValueError, match="already registered"):
        node.on("in")(lambda message: None)


def test_partial_fanout_is_not_acknowledged_or_retried():
    async def check():
        class PartialHost(Host):
            async def call(self, method, params):
                if method == "graph.forward" and params["output"] == "second":
                    self.calls.append((method, params))
                    raise RuntimeError("Second connection removed")
                return await super().call(method, params)
        host = PartialHost()
        node = Node("Fanout", inputs=["in"], outputs=["first", "second"], client=host)
        node.on("in")(lambda event: [Output(port="first"), Output(port="second")])
        with pytest.raises(ExceptionGroup):
            await node.serve()
        assert [p["output"] for m, p in host.calls if m == "graph.forward"] == ["first", "second"]
        assert not any(m == "graph.ack" for m, p in host.calls)
    asyncio.run(check())


def test_sync_handler_does_not_block_heartbeats():
    import time

    async def check():
        host = Host()
        node = Node("Slow", inputs=["in"], outputs=[], client=host)
        original_wait = node._wait
        async def quick_heartbeat(seconds):
            if seconds == 5:
                node.session._heartbeat_at = 0
            await original_wait(.01 if seconds == 5 else seconds)
        node._wait = quick_heartbeat
        loop = asyncio.get_running_loop()

        @node.on("in")
        def handler(message):
            time.sleep(.08)
            loop.call_soon_threadsafe(node.stop)

        await node.serve()
        methods = [m for m, p in host.calls]
        assert methods.index("agent.heartbeat") < methods.index("graph.ack")
    asyncio.run(check())


@pytest.mark.parametrize("mode", ["read", "turn_completed"])
def test_non_send_output_rejects_entire_fanout(mode):
    async def check():
        host = Host()
        node = Node("Mixed", inputs=["in"], outputs=["send", OutputPort(id="other", mode=mode)], client=host)
        node.on("in")(lambda event: [Output(port="send"), Output(port="other")])
        with pytest.raises(ExceptionGroup):
            await node.serve()
        assert not any(m in ("graph.forward", "graph.ack") for m, _ in host.calls)
        assert host.calls[-1][1]["event"] == "SessionEnd"
    asyncio.run(check())


def test_mutated_output_rejects_entire_fanout():
    async def check():
        host = Host()
        node = Node("Mutable payload", inputs=["in"], outputs=["out"], client=host)
        invalid = Output(port="out", payload={"result": True})
        invalid.payload["result"] = object()
        node.on("in")(lambda event: [Output(port="out"), invalid])
        with pytest.raises(ExceptionGroup):
            await node.serve()
        assert not any(m in ("graph.forward", "graph.ack") for m, _ in host.calls)
        assert any(m == "graph.progress" and p["status"] == "failed" for m, p in host.calls)
    asyncio.run(check())


def test_handler_output_data_is_copied_before_forwarding():
    async def check():
        original = Output(port="out", payload={"result": "original"})

        class MutatingHost(Host):
            async def call(self, method, params):
                result = await super().call(method, params)
                if method == "graph.forward":
                    original.payload["result"] = "changed"
                return result

        host = MutatingHost()
        node = Node("Snapshot", inputs=["in"], outputs=["out"], client=host)
        node.on("in")(lambda event: [original, original])
        await node.process(Event.model_validate(EVENT))
        assert [p["content"]["payload"] for m, p in host.calls if m == "graph.forward"] == [
            {"result": "original"}, {"result": "original"}]
    asyncio.run(check())
