"""Direct socket registration and inbox consumption."""
import asyncio
import contextlib
import logging
import os
import secrets
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

from common import Host, JudgeNode, Settings
from secret_input import openrouter_key

log = logging.getLogger("jev-node")


def create_app(settings=None, host=None, client=None, api_key=None):
    @asynccontextmanager
    async def lifespan(app):
        connection = host or Host()
        async with contextlib.AsyncExitStack() as stack:
            http = client or await stack.enter_async_context(httpx.AsyncClient(timeout=35))
            node = JudgeNode(settings or Settings.load(allow_json_env=False), connection, http, api_key=api_key if api_key is not None else openrouter_key())
            app.state.node = node
            app.state.delivery_lock = asyncio.Lock()
            app.state.inbox_healthy = True
            app.state.heartbeat_healthy = True
            await connection.call("agent.event", {
                "provider": "adapter", "event": "SessionStart",
                "session_id": f"jev-http-{os.getpid()}", "pid": os.getpid(),
            })

            await node.register()

            async def deliver(event_id=None):
                async with app.state.delivery_lock:
                    batch = await connection.call("graph.take", {})
                    events = batch["events"]
                    if event_id is not None:
                        events = [e for e in events if e["event_id"] == event_id]
                        if not events:
                            cached = node.receipts.get(event_id)
                            if cached:
                                return cached
                            raise HTTPException(404, "Event is not in this node's inbox")
                    if not events:
                        return None
                    receipt = await node.process(events[0])
                    await connection.call("graph.ack", {
                        "event_id": receipt["event_id"], "status": receipt["status"],
                    })
                    log.info("Event receipt: %s", receipt)
                    return receipt

            app.state.deliver = deliver

            async def pump():
                while True:
                    try:
                        await deliver()
                        app.state.inbox_healthy = True
                    except Exception as error:
                        app.state.inbox_healthy = False
                        log.error("Inbox failed: %s", type(error).__name__)
                    await asyncio.sleep(0.75)

            async def heartbeat():
                while True:
                    try:
                        await connection.call("agent.heartbeat", {})
                        app.state.heartbeat_healthy = True
                    except Exception as error:
                        app.state.heartbeat_healthy = False
                        log.error("Heartbeat failed: %s", type(error).__name__)
                    await asyncio.sleep(5)

            tasks = [asyncio.create_task(pump()), asyncio.create_task(heartbeat())]
            try:
                yield
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                with contextlib.suppress(Exception):
                    await connection.call("agent.event", {"provider": "adapter", "event": "SessionEnd"})

    app = FastAPI(title="Graffitty Jev node", lifespan=lifespan)

    def authorize(authorization: str = Header(default="")):
        expected = "Bearer " + app.state.node.host.token
        if not secrets.compare_digest(authorization, expected):
            raise HTTPException(401, "Graffitty bearer token required")

    @app.get("/health")
    def health():
        if not app.state.inbox_healthy or not app.state.heartbeat_healthy:
            raise HTTPException(503, "Host unavailable")
        return {"status": "ready"}

    @app.get("/manifest", dependencies=[Depends(authorize)])
    def manifest():
        return app.state.node.manifest()

    @app.post("/events/{event_id}", dependencies=[Depends(authorize)])
    async def process_event(event_id: str):
        # Read the authoritative event from the host; callers cannot inject paths.
        return await app.state.deliver(event_id)

    return app


app = create_app()


if __name__ == "__main__":
    import argparse
    import uvicorn
    parser = argparse.ArgumentParser(description="Jev node with optional HTTP API")
    parser.add_argument("--uds", help="Unix socket for this node's optional HTTP API (not the host socket)")
    parser.add_argument("--port", type=int, default=8765)
    api_key = openrouter_key()
    settings, args = Settings.from_cli(parser, allow_json_env=False)
    uvicorn.run(create_app(settings, api_key=api_key), uds=args.uds, host="127.0.0.1", port=args.port)
