# Rust graph SDK

Build a custom graph node with `graffitty-graph-protocol`.
The SDK handles registration, message delivery, and shutdown.

## Run the example

From a repository checkout, inside a Graffitty terminal:

```sh
cargo run -p graffitty-graph-protocol --example uppercase
```

Connect **Manual Prompt → Uppercase → Payload Inspector** and send `hello graph`.
The inspector should show `HELLO GRAPH`.

## Write a handler

```rust,no_run
use graffitty_graph_protocol::{Node, Output, Result};

fn main() -> Result<()> {
    let mut node = Node::new("Uppercase").input("in").output("out");
    node.on("in", |message| {
        Ok(Output::text("out", message.text.to_uppercase()))
    })?;
    node.run()
}
```

Declare the ports, add one handler per input, then call `run()`.
For the same example in Python, see the [Python SDK](../../docs/developers/automation-and-extensions/graph-python.md).

| Handler result | Result |
| --- | --- |
| `Result<Output>` | Forward one output |
| `Result<Vec<Output>>` | Forward several outputs |
| `Result<Option<Output>>` | Forward when `Some`, consume when `None` |
| `Result<()>` | Consume without forwarding |

Forwarding keeps the incoming run, session references, and sender information.
Use `with_content` and `with_renderings` for rich messages.

## Name and style ports

```rust
use graffitty_graph_protocol::{InputPort, LineStyle, Node, OutputPort};

let node = Node::new("Judge")
    .input(InputPort::new("in").name("Evaluate").icon("↓"))
    .output(OutputPort::new("approved").name("Approved").icon("✓")
        .line_style(LineStyle::Solid));
```

Keep IDs stable when changing labels. String declarations such as `.output("out")`
already use solid wires. For configured ports, choose `Solid` for automatic
output or `Dashed` when a later agent decision is required.

Handlers send through Send ports. Read grants transcript access; TurnCompleted
reports lifecycle completion. See [graph design](../../docs/developers/automation-and-extensions/agent-graph.md#connections-are-permissions).

## Use your own event loop

Use `Session` when an interactive program needs to control its own loop:

```rust,no_run
use graffitty_graph_protocol::{Client, Manifest, Result, Session};

fn main() -> Result<()> {
    let mut session = Session::start(Client::from_env()?, true)?;
    session.register(&Manifest::new("My node"))?;
    session.heartbeat()?;
    // Continue your loop here.
    Ok(())
}
```

| Operation | API |
| --- | --- |
| Receive and finish input | `take`, `ack` |
| Route existing input | `forward` |
| Start a new message | `emit` |
| Report status or lifecycle | `progress`, `event` |
| Other workspace operations | `call` |

Call `heartbeat()` regularly in a manual loop. `Node::run()` does this for you;
`run_until(client, stop)` lets you supply your own stop signal.
Give each completed `Stop` event a distinct `completion_id`.

## Restore after a checkpoint

Use `Node::new("Judge").restorable()` to let checkpoints relaunch your node.
Save state with `report_state(json!({...}))` and read it with `restored_state()`.

With a manual session, use `Session::start_restorable` and
`Restore::current_process()`. Store credential names rather than secret values.
See [checkpoints](../../docs/everyday-use/checkpoints.md) for recovery limits.

## Handle failures

The input is acknowledged after all outputs are sent. An error stops the node
and leaves the input pending; fix the cause and restart to resume.

A crash can happen after some outputs were sent. Use `event_id` to avoid
repeating external actions when retrying.

For API details, see the crate source and [graph design](../../docs/developers/automation-and-extensions/agent-graph.md).
Run SDK checks with `cargo test -p graffitty-graph-protocol`.
