# Python node lifecycle

Prefer [Node handlers](graph-python.md) for ordinary nodes.
Use `await node.serve()` inside an existing asyncio application; `node.run()`
owns a standalone loop. `node.stop()` stops after the current event.

## Use your own event loop

This consumer prints and acknowledges each received message:

```python
import asyncio
from graffitty_graph_protocol import InputPort, Manifest, Session

async def main():
    async with Session() as session:
        await session.register(Manifest(
            name="Print messages", inputs=[InputPort(id="in")], outputs=[]))
        while True:
            await session.heartbeat()
            for event in await session.take():
                print(event.text, flush=True)
                await session.ack(event.event_id)
            await asyncio.sleep(0.1)

asyncio.run(main())
```

For routing, call `forward(event_id, Output(...))` before `ack`.
`emit` creates a message; `event` reports lifecycle; `call(method, params)`
performs other permission-checked workspace operations. Give every completed
`Stop` event a distinct `completion_id`. Session references may be empty;
transcript paths still require Read permission.

## Restore after a checkpoint

1. Use `Node(..., restorable=True)`, or `Session(restore=Restore.current_process())`.
2. Save JSON with `await session.report_state({...})`.
3. Read `restored_state()` after relaunch.

Save credential names, not secret values. See [recovery limits](graph-delivery.md#checkpoint-recovery).
