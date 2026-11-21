# Agent graph design

Build nodes that exchange messages and session context through explicit connections.

- **Using agents?** Start with [setup](../../agents/agent-setup.md) and [connecting agents](../../agents/connect-agents.md).
- **Adding automation?** Try the [built-in nodes](../../agents/automation.md).
- **Writing a node?** Use the [Python SDK](graph-python.md) or [Rust SDK](graph-rust.md).

Use the SDK types and CLI help for individual fields and options.

## Connections are permissions

A connection from A's output to B's input determines what B receives or can read:

| Output | Meaning |
| --- | --- |
| Read | B may read A's session; connecting does not trigger a message. |
| Send | A may choose to send B a message. |
| Turn completed | Automatically notifies B when A completes a turn; also grants Read. |
| Waiting | Automatically notifies B when A needs input or approval. |
| Error | Automatically notifies B of a failure. |

- **Turn completed is not approval.** Check the result before acting on it.
- Waiting and Error do not grant transcript access.
- An interrupted turn emits neither completion nor failure.
- An idle agent is not necessarily waiting for human input.
- Connections stay within one tab. Moving a connected group carries its connections with it, including paused ones.

### Wire patterns

Patterns describe whether delivery depends on another agent decision:

| Pattern | Meaning | Examples |
| --- | --- | --- |
| Solid | The node emits automatically when its condition holds. | Turn completed, Manual Prompt, routing outputs, Parallel's combined result |
| Dashed | An agent must choose to read or send. | Read, agent-controlled Send |
| Dotted | The connection cannot act now. | Muted or expired connections |

For custom outputs:

- Set `line_style: "solid"` for automatic delivery, even when the condition may be false.
- Use `"dashed"` for an agent decision, or omit it to use the host default.
- Never declare `"dotted"`; the host reserves it for inactive connections.
- Style is a visual hint. It does not change permissions or delivery behavior.
- Use port metadata, not display names, to determine patterns. Drag and reconnect previews follow the same rules.

## CLI and MCP

Inspect the graph before granting access:

```sh
gft graph list
gft graph adjacent
gft graph connect --from %1 --to %2 --send --turn-completed
gft graph read --node %1
```

- `graph read` returns a session-file reference by default, avoiding a full transcript in the model's context.
- Add `--offset 0` to read bounded content; continue from the returned `next_offset`.
- Removing a connection revokes future graph access. It cannot revoke a file path already disclosed to a local process. **The graph is not an OS sandbox.**

## Launch a connected agent

To launch a connected agent from an integrated agent pane:

```sh
gft pane run --agent codex --name implementation --wire send,turn-completed,waiting,error
```

- `send`: caller may send to the child.
- `reply`: child may send to the caller.
- `read`: caller may read the child.
- `turn-completed`, `waiting`, `error`: child notifies the caller.
- Wiring waits for the child's ports to register; launch success does not mean the agent is ready.
- Closing the parent closes the child unless launched with `--outlive-parent`.

Use `gft graph --help` for commands, and `gft mcp --help` for MCP setup.

See [provider integration, delivery, retries, and node recovery](graph-delivery.md).
