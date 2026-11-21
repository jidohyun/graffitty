"""Registration and delivery for applications that own their event loop."""
import json
import os
import sys
import time

from pydantic import BaseModel, ConfigDict, Field

from .client import Client
from .models import Event, Manifest, Output


class Restore(BaseModel):
    """Declare how to relaunch this node from a checkpoint.

    Keep secret values out of the command and environment. Store a
    reference such as a credential name in secrets.toml, then resolve
    it again after relaunch.
    """
    model_config = ConfigDict(extra="forbid", frozen=True)
    command: list[str] = Field(min_length=1, max_length=64)
    cwd: str | None = None
    env: dict[str, str] = Field(default_factory=dict, max_length=32)

    @classmethod
    def current_process(cls) -> "Restore":
        """This process's own interpreter, arguments and working directory."""
        return cls(command=[sys.executable, *sys.orig_argv[1:]], cwd=os.getcwd())

    def to_wire(self) -> dict:
        return self.model_dump(exclude_none=True, exclude_defaults=True)


def restored_state():
    """The state this node reported before the checkpoint that relaunched it."""
    path = os.environ.get("GRAFFITTY_NODE_STATE")
    if not path:
        return None
    with open(path, encoding="utf-8") as file:
        return json.load(file)


class Session:
    """Register a graph session with its own event loop.

    Enter with ``async with Session(...)`` and await ``heartbeat()`` while the
    UI runs. Use ``call()`` for graph RPCs such as discovery, connections,
    permission-checked transcript reads, queue inspection, and run budgets.
    """

    def __init__(self, client: Client | None = None, *, provider: str | None = None,
                 resume_inbox: bool = True, restore: Restore | None = None):
        """``restore`` opts in to checkpoint recovery: a restore runs it in this
        node's pane, and ``restored_state()`` returns its last reported state."""
        self._client = client
        self.restore = restore
        self._identity = dict(kind="custom")
        if provider is not None:
            self._identity["provider"] = provider
        self.resume_inbox = resume_inbox
        self._started = False
        self._heartbeat_at = 0.0

    async def call(self, method: str, params: dict) -> dict:
        if self._client is None:
            self._client = Client()
        return await self._client.call(method, params)

    async def event(self, event: str, fields: dict | None = None) -> dict:
        """Report metadata or a completed turn (Stop), preserving node identity."""
        params = dict(fields or {})
        params.pop("provider", None)
        return await self.call("agent.event", {**params, **self._identity, "event": event})

    async def __aenter__(self):
        if self._started:
            raise RuntimeError("Session is already running")
        start = dict(pid=os.getpid(), resume_inbox=self.resume_inbox, transport="inbox")
        if self.restore is not None:
            start["restore"] = self.restore.to_wire()
        await self.event("SessionStart", start)
        self._started = True
        self._heartbeat_at = time.monotonic()
        return self

    async def __aexit__(self, *_):
        try:
            await self.event("SessionEnd")
        except Exception:
            # Preserve an application exception, just like Rust's Drop cleanup.
            pass
        finally:
            self._started = False

    async def report_state(self, state):
        """Keep ``state``, any JSON up to 64 KiB, for the next relaunch from a
        checkpoint; ``None`` clears it. Never include secret values."""
        await self.call("agent.checkpoint", dict(state=state))

    async def register(self, manifest: Manifest):
        # Revalidate mutable port arrays and metadata before touching the host.
        manifest = Manifest.model_validate(manifest.to_wire())
        await self.call("agent.register", manifest.to_wire())

    async def heartbeat(self):
        if time.monotonic() - self._heartbeat_at >= 5:
            await self.call("agent.heartbeat", {})
            self._heartbeat_at = time.monotonic()

    async def take_raw(self) -> list[dict]:
        result = await self.call("graph.take", {})
        if not isinstance(result.get("events"), list):
            raise ValueError("Invalid host inbox response")
        return result["events"]

    async def take(self) -> list[Event]:
        return [Event.model_validate(event) for event in await self.take_raw()]

    async def ack(self, event_id: str, status: str = "delivered"):
        await self.call("graph.ack", dict(event_id=event_id, status=status))

    async def progress(self, event_id: str, status: str, message: str, details=None):
        if status not in ("pending", "failed"):
            raise ValueError("Invalid progress status")
        await self.call("graph.progress", dict(event_id=event_id, status=status, message=message,
                                               details={} if details is None else details))

    async def forward(self, event_id: str, output: Output) -> dict:
        result = await self.call("graph.forward", dict(event_id=event_id, output=output.port,
                                                       content=output.overrides()))
        if result.get("status") != "queued":
            raise RuntimeError("Output was not queued; input retained")
        return result

    async def emit(self, output: Output, *, run_id: str | None = None, outcome: str | None = None) -> dict:
        """Start a message on a Send port, with null payload when it is omitted."""
        params = {"payload": None, **output.overrides(), "output": output.port}
        if run_id is not None:
            params["run_id"] = run_id
        if outcome is not None:
            params["outcome"] = outcome
        result = await self.call("graph.emit", params)
        if result.get("status") != "queued":
            raise RuntimeError("Output was not queued")
        return result
