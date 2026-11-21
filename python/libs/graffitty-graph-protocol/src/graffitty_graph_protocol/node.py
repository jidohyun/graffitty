"""Small bot-style API; no JSON plumbing in user handlers."""
import asyncio
import inspect
import signal
import threading
from collections.abc import Awaitable, Callable

from .client import Client
from .models import Event, Icon, InputPort, Manifest, Output, OutputPort
from .session import Restore, Session

HandlerResult = Output | list[Output] | None
Handler = Callable[[Event], HandlerResult | Awaitable[HandlerResult]]


class Node:
    def __init__(self, name: str, *, inputs: list[str | InputPort], outputs: list[str | OutputPort],
                 client: Client | None = None, poll_interval: float = 0.25,
                 provider: str | None = None, icon: Icon | str | dict[str, str] | None = None,
                 restorable: bool = False):
        """``restorable`` lets a checkpoint relaunch this node with its own command line."""
        self.manifest = Manifest(name=name, icon=icon,
            inputs=[InputPort(id=p) if isinstance(p, str) else p for p in inputs],
            outputs=[OutputPort(id=p, line_style="solid") if isinstance(p, str) else p for p in outputs])
        self.session = Session(client, provider=provider, restore=Restore.current_process() if restorable else None)
        self._handlers: dict[str, Handler] = {}
        self._stop = asyncio.Event()
        self._running = False
        if poll_interval <= 0:
            raise ValueError("poll_interval must be positive")
        self.poll_interval = poll_interval

    def on(self, input_port: str):
        """Register exactly one handler for an advertised input port."""
        if input_port not in {p.id for p in self.manifest.inputs}:
            raise ValueError(f"Unknown input: {input_port}")

        def register(handler: Handler):
            if input_port in self._handlers:
                raise ValueError(f"Handler already registered: {input_port}")
            self._handlers[input_port] = handler
            return handler
        return register

    def stop(self):
        """Stop after the current event. Call from the node's event loop."""
        self._stop.set()

    async def process(self, event: Event):
        """Forward every result before acknowledging; failure leaves input pending."""
        try:
            handler = self._handlers[event.target_port]
            result = (await handler(event) if inspect.iscoroutinefunction(handler)
                      else await asyncio.to_thread(handler, event))
            if inspect.isawaitable(result):
                result = await result
            outputs = [] if result is None else [result] if isinstance(result, Output) else result
            if not isinstance(outputs, list) or not all(isinstance(o, Output) for o in outputs):
                raise TypeError("Handlers return Output, list[Output], or None")
            # Freeze a validated copy of every branch before the first network await.
            outputs = [output.validated() for output in outputs]
            for output in outputs:
                port = next((p for p in self.manifest.outputs if p.id == output.port), None)
                if port is None:
                    raise ValueError(f"Unknown output: {output.port}")
                if port.mode != "send":
                    raise ValueError(f"Handler outputs require Send mode: {output.port}")
            for output in outputs:
                await self.session.forward(event.event_id, output)
            await self.session.ack(event.event_id)
        except Exception:
            # Do not acknowledge or automatically retry side effects. The host's
            # queue survives a restart; traceback details stay in this terminal.
            try:
                await self.session.progress(event.event_id, "failed",
                    "Python handler failed; inspect the node terminal")
            except Exception:
                pass
            raise

    async def _wait(self, seconds):
        try:
            await asyncio.wait_for(self._stop.wait(), seconds)
        except TimeoutError:
            pass

    async def _heartbeat(self):
        while not self._stop.is_set():
            await self._wait(5)
            if not self._stop.is_set():
                await self.session.heartbeat()

    async def _consume(self):
        while not self._stop.is_set():
            for raw in await self.session.take_raw():
                if self._stop.is_set():
                    break
                try:
                    event = Event.model_validate(raw)
                except Exception:
                    if isinstance(raw, dict) and isinstance(raw.get("event_id"), str):
                        await self.session.progress(raw["event_id"], "failed", "Invalid graph event")
                    raise
                await self.process(event)
            await self._wait(self.poll_interval)

    async def serve(self):
        """Async entry point for programs that already own an event loop."""
        if self._running:
            raise RuntimeError("Node is already running")
        missing = {p.id for p in self.manifest.inputs} - self._handlers.keys()
        if missing:
            raise ValueError(f"Missing handlers: {', '.join(sorted(missing))}")
        self._running = True
        self._stop.clear()
        try:
            async with self.session:
                await self.session.register(self.manifest)
                print(f"{self.manifest.name} · waiting for events", flush=True)
                async with asyncio.TaskGroup() as tasks:
                    tasks.create_task(self._heartbeat())
                    tasks.create_task(self._consume())
        finally:
            self._running = False

    def run(self):
        """Run directly with `uv run node.py`; no adapter wrapper is needed."""
        def interrupt(signum, frame):
            raise KeyboardInterrupt
        main_thread = threading.current_thread() is threading.main_thread()
        previous = signal.signal(signal.SIGTERM, interrupt) if main_thread else None
        try:
            asyncio.run(self.serve())
        except KeyboardInterrupt:
            pass
        finally:
            if main_thread:
                signal.signal(signal.SIGTERM, previous)
