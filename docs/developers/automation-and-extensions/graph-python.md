# Python graph SDK

Turn a Python function into a node you can connect to agents and other tools.
The SDK handles registration and message delivery.

## Run your first node

Requires Python 3.11+ and a running Graffitty workspace.

1. Install the SDK:

   ```sh
   pip install graffitty-graph-protocol
   ```

2. Save this as `node.py`:

   ```python
   from graffitty_graph_protocol import Event, Node, Output

   node = Node("Uppercase", inputs=["in"], outputs=["out"])

   @node.on("in")
   def uppercase(message: Event):
       return Output(port="out", text=message.text.upper())

   node.run()
   ```

3. Run it inside a Graffitty terminal, using the Python environment where you installed the SDK:

   ```sh
   python node.py
   ```

4. Connect **Manual Prompt → Uppercase → Payload Inspector**. Send `hello graph`.
   The inspector should show `HELLO GRAPH`.

## Choose what to return

Handlers can use `def` or `async def`. Give every declared input one handler.

| Return value | Result |
| --- | --- |
| `Output(port="out", text="hello")` | Replace the text and forward |
| `Output(port="out")` | Forward unchanged |
| A list of `Output` objects | Forward to several outputs |
| `None` | Consume without forwarding |

`message.payload` holds custom JSON. Validate it with your own Pydantic model
if your application needs a schema.

Set `payload`, `content`, or `renderings` on `Output` to replace those fields.
Omitted fields keep their incoming values; `payload=None` clears the payload.
Forwarding keeps the original run, session references, and sender information.

## Name and style ports

Use simple string IDs unless you need custom names, colors, or icons:

```python
from graffitty_graph_protocol import InputPort, Node, OutputPort

node = Node("Judge",
    inputs=[InputPort(id="in", name="Evaluate", icon="↓")],
    outputs=[OutputPort(id="approved", name="Approved", icon="✓",
                        line_style="solid")])
```

Keep IDs stable when changing labels. Use **solid** for outputs your code sends
automatically and **dashed** when a later agent decision is required.
String output declarations already use solid wires.

Handlers send through Send ports. Read grants transcript access; Turn completed
reports lifecycle completion. See [graph design](agent-graph.md#connections-are-permissions).

## Handle failures

Handlers process one event at a time. A failure stops the runtime and leaves the
input pending. Fix the cause and restart to resume.

A crash can happen after an output was sent. Use `event_id` to avoid repeating
external actions, such as posting a message, when retrying.

Run nodes inside Graffitty so they inherit the host connection. For repository
checks, see the package README and shared fixtures in `tests/fixtures/graph-manifests.json`.

See [custom event loops and checkpoint restoration](graph-python-lifecycle.md).
