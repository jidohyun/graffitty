import asyncio

import pytest

from graffitty_graph_protocol import Manifest, Output, Session
from test_node import EVENT, Host


def test_explicit_session_lifecycle_and_delivery():
    async def check():
        class SessionHost(Host):
            async def call(self, method, params):
                result = await super().call(method, params)
                return {"status": "queued"} if method == "graph.emit" else result
        host = SessionHost()
        with pytest.raises(RuntimeError, match="application failed"):
            async with Session(host, provider="telegram") as session:
                await session.register(Manifest(inputs=[], outputs=[]))
                events = await session.take()
                assert events[0].event_id == EVENT["event_id"]
                await session.emit(Output(port="out", text="hello"), run_id="run", outcome="approved")
                await session.forward(events[0].event_id, Output(port="out", payload=None))
                await session.ack(events[0].event_id)
                await session.event("Stop", dict(text="finished", kind="agent", provider="forged"))
                session._heartbeat_at = 0
                await session.heartbeat()
                await session.heartbeat()
                raise RuntimeError("application failed")
        assert host.calls[0][1]["transport"] == "inbox"
        assert host.calls[-1][1] == dict(kind="custom", provider="telegram", event="SessionEnd")
        assert sum(m == "agent.heartbeat" for m, _ in host.calls) == 1
        assert next(p for m, p in host.calls if m == "graph.emit") == dict(
            output="out", payload=None, text="hello", run_id="run", outcome="approved")
        assert next(p for m, p in host.calls if m == "agent.event" and p["event"] == "Stop")["provider"] == "telegram"
    asyncio.run(check())


def test_registration_failure_closes_session():
    async def check():
        host = Host(fail="agent.register")
        with pytest.raises(RuntimeError):
            async with Session(host) as session:
                await session.register(Manifest(inputs=[], outputs=[]))
        assert host.calls[-1][1]["event"] == "SessionEnd"
    asyncio.run(check())


def test_restorable_node_declares_its_relaunch_and_reports_state(tmp_path, monkeypatch):
    from graffitty_graph_protocol import Node, Restore, restored_state
    async def check():
        host = Host()
        restore = Restore(command=["/usr/bin/python3", "judge.py"], cwd="/work", env={"MODE": "strict"})
        async with Session(host, restore=restore) as session:
            await session.report_state({"cursor": 3})
        start = host.calls[0][1]
        assert start["restore"] == {"command": ["/usr/bin/python3", "judge.py"], "cwd": "/work", "env": {"MODE": "strict"}}
        assert ("agent.checkpoint", {"state": {"cursor": 3}}) in host.calls
        # Without opting in, nothing describes a relaunch.
        plain = Host()
        async with Session(plain):
            pass
        assert "restore" not in plain.calls[0][1]
    asyncio.run(check())
    own = Node("judge", inputs=[], outputs=[], restorable=True).session.restore
    assert own.command[0] and own.cwd and own.to_wire()["command"] == own.command
    assert restored_state() is None
    state = tmp_path / "state.json"
    state.write_text('{"cursor": 3}')
    monkeypatch.setenv("GRAFFITTY_NODE_STATE", str(state))
    assert restored_state() == {"cursor": 3}
    with pytest.raises(ValueError):
        Restore(command=[])
