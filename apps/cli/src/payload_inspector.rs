//! Socket-only event inspection. stdout belongs to the user, never the protocol.
use crate::{agent_bridge::Result, options::PayloadInspector};
use serde_json::json;
use std::{
    io::{self, Write},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration},
};

static STOP: AtomicBool = AtomicBool::new(false);

fn timestamp() -> String {
    jiff::Zoned::now().strftime("%Y-%m-%d %H:%M:%S %z").to_string()
}

extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

pub fn run(args: PayloadInspector) -> Result<()> {
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut graph_session = crate::node_session(true)?;
    graph_session.register_raw(json!({
            "name":args.name.unwrap_or_else(|| "Payload Inspector".into()), "icon":"⌕",
            "inputs":[{"id":"payload","name":"Payload","color":"#8ecaff"}],"outputs":[]
        }),
    )?;
    if !args.json {
        eprintln!(
            "Payload Inspector · waiting for events\nConnect an output to Payload. Ctrl+C to exit."
        );
    }
    let mut stdout = io::stdout().lock();
    while !STOP.load(Ordering::Relaxed) {
        graph_session.heartbeat()?;
        let batch = graph_session.take_raw()?;
        for event in &batch {
            if STOP.load(Ordering::Relaxed) {
                break;
            }
            // JSON escapes terminal control characters. Preserve the full envelope,
            // arbitrary payload, and session references without opening session files.
            let rendered = if args.json {
                serde_json::to_string(event)?
            } else {
                serde_json::to_string_pretty(event)?
            };
            if !args.json {
                writeln!(stdout, "[{}]", timestamp())?;
            }
            writeln!(stdout, "{rendered}")?;
            if !args.json {
                writeln!(stdout)?;
            }
            stdout.flush()?;
            // Never remove an event before its output has been successfully written.
            graph_session.ack(event["event_id"].as_str().ok_or("Host event has no ID")?)?;
            if args.once {
                return Ok(());
            }
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    Ok(())
}
