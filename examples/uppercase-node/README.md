# Minimal Python graph node

Run in this directory inside a Graffitty terminal, with `uv` on your PATH:

```sh
uv run node.py
```

Connect **Manual Prompt → Uppercase → Payload Inspector**, then send `hello graph`.
The inspector receives `HELLO GRAPH`.

The [Pydantic SDK](../../python/libs/graffitty-graph-protocol/README.md) registers
the ports, validates messages, forwards the handler's output, then acknowledges
receipt. The run and session references are preserved. The local dependency is
configured in `pyproject.toml`; uv installs it automatically.

The output is solid because this code forwards every received message
automatically. stdin/stdout are available to your program; no adapter is needed.

See the [graph protocol](../../docs/developers/automation-and-extensions/agent-graph.md) for the event format and APIs.
