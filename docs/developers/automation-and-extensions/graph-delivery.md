# Graph delivery and node contracts

The server owns delivery queues. Use SDK `Node` handlers unless your application
needs its own loop. [Connections](agent-graph.md#connections-are-permissions)
grant permissions, not an OS sandbox.

## Delivery lifetime

| State | Meaning |
| --- | --- |
| Queued | Waiting at the source |
| Processing | Receiver has the event; input remains pending |
| Acknowledged | Receiver finished handling it; not necessarily a completed model turn |
| Failed/cancelled | Inspect the reason before retrying |

Inspecting a queue does not consume or resend. Progress reports, including
failure reports, leave input pending. Acknowledge only after handling succeeds.

### Retries and external effects

Fan-out is not atomic: a crash can follow partial delivery. Deduplicate external
side effects with `event_id`. Check uncertain sends before retrying; the first
attempt may have succeeded. Cancellation cannot recall consumed work.

### Forwarding versus emitting

| Operation | Use |
| --- | --- |
| Forward | Transform/route an input; preserve run, sessions, and origin |
| Emit | Create new content |
| Acknowledge | Finish the input after successful work |

Forwarding does not acknowledge or grant new Read permission to original sources.
Provide readable fallback text for rich content; payload objects are not
implicitly serialized into chat messages.

## Agent integration

Deliver through **native provider queues**, never simulated typing.
Require the exact session; ambiguous identity fails rather than choosing the
newest transcript. Attaching history must not replay old completions.

| Provider rule | Consequence |
| --- | --- |
| Codex needs its daemon queue | Detection of a local/embedded session alone is insufficient |
| Pi needs idle agent and queue | An admitted native message cannot be individually cancelled |
| Queue accepts input | This does not mean a model turn finished |

### Typing guard

Wait three seconds after human typing, across viewers of the terminal.
An abandoned draft is not a permanent block. Typing after admission does not
cancel the admitted message.

## Custom-node identity, input and output ports

| Requirement | Value |
| --- | --- |
| Port arrays | Declare both, even when empty |
| Ports | At most 32 per side |
| ID | 1–64 ASCII letters, digits, `_`, `-` |
| Presentation | Labels, colors, icons may change; IDs remain stable |

Removing an ID removes its wires and cancels pending deliveries.
Custom nodes must not impersonate built-in providers. SDK runtimes manage
registration and heartbeats.

### Loops and limits

| Boundary | Rule |
| --- | --- |
| Reply in a workflow | Preserve incoming `run_id` |
| New human prompt | Start a new run |
| Queue / run defaults | 10,000 events |
| Request size | 4 MiB; Claude delivery 1 MiB |
| Large shell input | Use `--text -` for stdin |

Inspector defaults affect new runs. Changing a selected run's budget or resetting
its count does not empty queues. Stop modes are **Never**, **After**, and **At**.
Relative deadlines resolve on Apply; reopening does not reset them.
Expiry cancels pending work while a running turn can finish.

## Checkpoint recovery

Checkpoints restore configuration, not in-flight work.

1. Opt in with a launch command, directory, environment, and saved state.
2. Save credential references rather than values.
3. Restore useful drafts/settings without repeating completed external actions.

Pending deliveries are not replayed. `resume_inbox` handles process restart,
not checkpoint replay. Only local history may restore commands; imported
snapshots reopen shells.

Python uses `Node(..., restorable=True)`; Rust uses `.restorable()`.
See [checkpoints](../../everyday-use/checkpoints.md) for user-facing limits.
