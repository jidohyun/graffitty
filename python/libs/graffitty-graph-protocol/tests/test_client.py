import asyncio
import json

import pytest

from graffitty_graph_protocol import Client, GraphError
from graffitty_graph_protocol.client import MAX_REQUEST


@pytest.mark.parametrize("mode", ["ok", "error", "wrong_id", "incomplete", "timeout"])
def test_rpc_validation(mode):
    async def check():
        requests = []
        async def handle(reader, writer):
            request = json.loads(await reader.readline())
            requests.append(request)
            try:
                if mode == "timeout":
                    await reader.read()
                    return
                reply = {"id": "wrong" if mode == "wrong_id" else request["id"], "result": {"ok": True}}
                if mode == "error":
                    reply = {"id": request["id"], "error": {"code": "denied", "message": "Permission denied"}}
                writer.write((json.dumps(reply) + ("" if mode == "incomplete" else "\n")).encode())
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()
        server = await asyncio.start_server(handle, "127.0.0.1", 0)
        async with server:
            client = Client(f"tcp://127.0.0.1:{server.sockets[0].getsockname()[1]}", "private-token", timeout=.1)
            assert "private-token" not in repr(client)
            if mode == "ok":
                assert await client.call("agent.heartbeat", {}) == {"ok": True}
            else:
                with pytest.raises(GraphError if mode == "error" else TimeoutError if mode == "timeout" else ValueError):
                    await client.call("agent.heartbeat", {})
            assert requests[0]["token"] == "private-token"
            assert requests[0]["version"] == 1
    asyncio.run(check())


def test_size_and_remote_endpoint_rejected_without_connecting():
    async def check():
        with pytest.raises(ValueError, match="exceeds"):
            await Client("/missing", "test").call("graph.emit", {"text": "x" * MAX_REQUEST})
        with pytest.raises(ValueError, match="loopback"):
            await Client("tcp://192.0.2.1:123", "test").call("graph.take", {})
    asyncio.run(check())
