# Connect agents

Connections let agents share information and hand work to one another.
First [set up your agents](agent-setup.md) and open them in panes in the same tab.

## Make a connection

1. Zoom out until connection dots appear beside the agent panes.
2. Drag an output on the right to **Receive** on another agent's left.
3. Release to connect, or press **Escape** to cancel.

For a connection from agent A to agent B:

| Output on A | What it does |
| --- | --- |
| **Read** | Allows B to read A's conversation when B chooses to. |
| **Send** | Allows A to choose to send a message to B. |
| **Turn completed** | Notifies B when A finishes a turn and lets B read A's conversation. |
| **Waiting** | Notifies B when A needs permission or an answer. |
| **Error** | Notifies B when A stops with a provider failure. |

For a review workflow, connect **Turn completed → Receive** and tell the receiver
what to review. Completion is not proof of success or approval.
Connections stay in one tab; moving a pane carries its connected group.

## From the command line

Run these commands in a Graffitty terminal. Inspect the graph to find the two
agents' pane IDs, then connect the sender's completed turns to the receiver:

```sh
gft graph list
gft graph connect --from %1 --to %2 --turn-completed
```

Replace `%1` and `%2` with the sender and receiver IDs from the listing.
Use `--send` for agent-chosen messages or `--read` to grant conversation access
without an automatic trigger.

For other graph nodes, use the advertised output and input IDs with
`--from-port` and `--to-port`. See [Automation nodes](automation.md) for the
commands that start each node, then wire its ports as described there.

## Read the lines

- **Solid:** delivery is automatic when the output's condition occurs.
- **Dashed:** an agent must decide to read or send.
- **Dotted:** the connection is paused or expired and cannot act.

A connection grants an ability; a dashed line does not guarantee the agent will use it.

## Pause or remove a connection

Right-click a line, or press and hold it, to open its menu:

- **Pause connection:** hold future delivery; work already started can finish.
- **Remove connection:** disconnect the nodes.
- **Queue Inspector:** inspect waiting messages.

To edit the wiring:

- Drag an input end to another input to reconnect it.
- Drop it in empty space to disconnect.
- Use **Undo / Redo** for graph edits. Undo does not restore cancelled messages.

For more workflows, see [chat integrations](chat-integrations.md) and
[desktop notifications](system-notification.md).
