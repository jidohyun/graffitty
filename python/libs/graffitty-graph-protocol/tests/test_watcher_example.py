import asyncio
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest


@pytest.mark.parametrize("exit_code, sends", [(0, 1), (1, 0)])
def test_watcher_forwards_command_output_once_on_success(monkeypatch, exit_code, sends):
    path = Path(__file__).resolve().parents[4] / "examples/watcher-node/node.py"
    spec = importlib.util.spec_from_file_location("watcher_example", path)
    example = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(example)
    node = SimpleNamespace(register=AsyncMock(), heartbeat=AsyncMock(), emit=AsyncMock())

    class Session:
        async def __aenter__(self):
            return node

        async def __aexit__(self, *args):
            return False

    # Larger than a pipe buffer: drain stdout while waiting, preserve Unicode,
    # and never deliver output from a failed command.
    message = "New email: 출시 일정\n" + "x" * 131072
    command = "import sys; sys.stdout.write(" + repr(message) + "); sys.exit(" + str(exit_code) + ")"
    monkeypatch.setattr(example, "Session", Session)
    monkeypatch.setattr(example.sys, "argv", ["node.py", sys.executable, "-c", command])
    asyncio.run(asyncio.wait_for(example.main(), timeout=5))

    manifest = node.register.await_args.args[0]
    assert manifest.inputs == []
    assert [port.id for port in manifest.outputs] == ["done"]
    assert manifest.outputs[0].line_style == "solid"
    assert node.heartbeat.await_count >= 1
    assert node.emit.await_count == sends
    if sends:
        output = node.emit.await_args.args[0]
        assert output.port == "done"
        assert output.text == message
