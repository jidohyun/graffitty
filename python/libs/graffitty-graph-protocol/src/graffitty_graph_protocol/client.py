"""The same newline-delimited, authenticated local RPC used by the Rust SDK."""
import asyncio
import ipaddress
import json
import os
from urllib.parse import urlsplit
from uuid import uuid4

MAX_REQUEST = 4 * 1024 * 1024
MAX_MESSAGE = MAX_REQUEST + 68 * 1024


class GraphError(RuntimeError):
    def __init__(self, method, error):
        self.method = method
        self.code = error.get("code", "unknown")
        super().__init__(f"{method}: {error.get('message', 'Host rejected request')}")


class Client:
    def __init__(self, endpoint: str | None = None, token: str | None = None, *, timeout: float = 5):
        self.endpoint = endpoint if endpoint is not None else os.environ.get("GRAFFITTY_SOCKET", "")
        self._token = token if token is not None else os.environ.get("GRAFFITTY_TOKEN", "")
        self.timeout = timeout
        if not self.endpoint or not self._token:
            raise ValueError("Run inside a Graffitty pane (GRAFFITTY_SOCKET/TOKEN required)")
        if timeout <= 0:
            raise ValueError("timeout must be positive")

    async def call(self, method: str, params: dict) -> dict:
        if not isinstance(params, dict):
            raise TypeError("Expected a JSON object")
        request = dict(id=str(uuid4()), version=1, token=self._token, method=method, params=params)
        data = (json.dumps(request, ensure_ascii=False, allow_nan=False) + "\n").encode()
        if len(data) > MAX_REQUEST:
            raise ValueError(f"API request exceeds {MAX_REQUEST} bytes; send a file path instead")
        async with asyncio.timeout(self.timeout):
            if os.name == "nt" and self.endpoint.startswith("ipc://"):
                # The CLI already supports Windows named pipes with bounded I/O.
                # Keep the same pane context; inherited Codex thread discovery is
                # appropriate for agent tools, not an explicitly launched node.
                env = {k: v for k, v in os.environ.items() if k != "CODEX_THREAD_ID"}
                env.update(GRAFFITTY_SOCKET=self.endpoint, GRAFFITTY_TOKEN=self._token)
                process = await asyncio.create_subprocess_exec(os.environ.get("GRAFFITTY_BIN", "gft"),
                    "rpc", method, "--params", json.dumps(params), env=env,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                try:
                    stdout, _ = await process.communicate()
                    reply = json.loads(stdout)
                finally:
                    if process.returncode is None:
                        process.kill()
                        await process.wait()
                # gft generates and checks its own request ID.
            else:
                if self.endpoint.startswith("tcp://"):
                    address = urlsplit(self.endpoint)
                    if not address.hostname or not ipaddress.ip_address(address.hostname).is_loopback:
                        raise ValueError("Graph TCP endpoint must be a loopback IP address")
                    if address.port is None or address.path or address.query or address.fragment or address.username:
                        raise ValueError("Invalid graph TCP endpoint")
                    reader, writer = await asyncio.open_connection(address.hostname, address.port, limit=MAX_MESSAGE)
                else:
                    reader, writer = await asyncio.open_unix_connection(self.endpoint.removeprefix("ipc://"), limit=MAX_MESSAGE)
                try:
                    writer.write(data)
                    await writer.drain()
                    line = await reader.readline()
                    if len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
                        raise ValueError("Incomplete or oversized API response")
                    reply = json.loads(line)
                finally:
                    writer.close()
                    await writer.wait_closed()
                if not isinstance(reply, dict) or reply.get("id") != request["id"]:
                    raise ValueError("Mismatched API response ID")
        if not isinstance(reply, dict) or (("result" in reply) == ("error" in reply)):
            raise ValueError("Invalid API response")
        if "error" in reply:
            raise GraphError(method, reply["error"])
        return reply["result"]
