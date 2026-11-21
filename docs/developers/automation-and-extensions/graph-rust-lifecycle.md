# Rust node lifecycle

Prefer [Node handlers](graph-rust.md) for ordinary nodes.
`Node::run()` handles registration and heartbeat; `run_until(client, stop)`
adds your own stop signal.

## Use your own event loop

This consumer prints and acknowledges received messages:

```rust,no_run
use graffitty_graph_protocol::{Client, InputPort, Manifest, Result, Session};
use std::{thread, time::Duration};

fn main() -> Result<()> {
    let mut session = Session::start(Client::from_env()?, true)?;
    let mut manifest = Manifest::new("Print messages");
    manifest.inputs.push(InputPort::new("in"));
    session.register(&manifest)?;
    loop {
        session.heartbeat()?;
        for event in session.take()? {
            println!("{}", event.text);
            session.ack(&event.event_id)?;
        }
        thread::sleep(Duration::from_millis(100));
    }
}
```

For routing, `forward(event_id, &output)` precedes `ack`.
`emit` creates messages; `progress`/`event` report state;
`call` performs permission-checked operations. Give every completed `Stop`
event a distinct `completion_id`.

## Restore after a checkpoint

Use `Node::new("Judge").restorable()` or
`Session::start_restorable(client, None, true, &Restore::current_process()?)`.
Save JSON with `report_state` and load `restored_state()` after relaunch.
Save credential names rather than secret values.
See [recovery limits](graph-delivery.md#checkpoint-recovery).
