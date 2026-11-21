//! A socket-only, FIFO join. The host retains inputs until output is queued.
use crate::node_rpc as rpc;
use crate::{agent_bridge::Result, options::Parallel};
#[path = "parallel_display.rs"]
mod display;
use display::Display;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Wire {
    source: String,
    output: String,
    input: String,
    revision: String,
}
impl Wire {
    fn edge(v: &Value) -> Self {
        Self {
            source: string(v, "from"),
            output: string(v, "from_port"),
            input: string(v, "to_port"),
            revision: v["revision"].to_string(),
        }
    }
    fn event(v: &Value) -> Self {
        Self {
            source: string(v, "source"),
            output: string(v, "source_port"),
            input: string(v, "target_port"),
            revision: v["edge_revision"].to_string(),
        }
    }
}
fn string(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_owned()
}
fn wires(adjacent: &Value) -> Vec<Wire> {
    let mut values: Vec<_> = adjacent["incoming"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|v| {
            v["muted"] != true
                && (v["send"] == true || v["turn_completed"] == true)
                && v["to_port"] == "join"
        })
        .map(Wire::edge)
        .collect();
    values.sort();
    values.dedup();
    values
}
#[derive(Default)]
struct Round {
    expected: Vec<Wire>,
    received: BTreeMap<Wire, Value>,
    titles: BTreeMap<Wire, String>,
}
impl Round {
    fn update_titles(&mut self, adjacent: &Value) {
        for edge in adjacent["incoming"].as_array().into_iter().flatten() {
            let title = string(edge, "from_title");
            self.titles.insert(
                Wire::edge(edge),
                if title.trim().is_empty() {
                    "Untitled terminal".into()
                } else {
                    title
                },
            );
        }
    }
    fn label(&self, wire: &Wire) -> String {
        format!(
            "{} / {}",
            self.titles
                .get(wire)
                .map(String::as_str)
                .unwrap_or("Untitled terminal"),
            wire.output
        )
        .chars()
        .filter(|c| !c.is_control())
        .collect()
    }
    fn ingest(&mut self, edges: Vec<Wire>, events: &[Value]) -> Result<Vec<Value>> {
        if self.received.is_empty() {
            self.expected = edges;
        } else if self.expected != edges {
            return Err("Parallel wiring changed during a pending round. Inputs remain in the host inbox; restore the wiring or restart Parallel to use the new wires.".into());
        }
        let mut accepted = Vec::new();
        for event in events {
            let wire = Wire::event(event);
            if self.expected.contains(&wire) && !string(event, "event_id").is_empty() {
                if let std::collections::btree_map::Entry::Vacant(entry) = self.received.entry(wire)
                {
                    entry.insert(event.clone());
                    accepted.push(event.clone());
                }
            }
        }
        Ok(accepted)
    }
    fn complete(&self) -> bool {
        !self.expected.is_empty() && self.received.len() == self.expected.len()
    }
    fn payload(&self, round: u64) -> Value {
        let inputs: Vec<_> = self
            .expected
            .iter()
            .map(|wire| self.received[wire].clone())
            .collect();
        let mut text = format!(
            "Parallel round {round}: all {} branches completed.\n",
            inputs.len()
        );
        for event in &inputs {
            text.push_str(&format!(
                "\n--- {} / {} ---\n{}\nSessions: {}\n",
                crate::integration::pane_label(&string(event, "source")),
                string(event, "source_port"),
                string(event, "text"),
                event["sessions"]
            ));
        }
        json!({"type":"parallel.completed", "round":round, "text":text, "inputs":inputs})
    }
}

pub fn run(args: Parallel) -> Result<()> {
    let name = args.name.unwrap_or_else(|| "Parallel".into());
    let mut graph_session = crate::node_session(true)?;
    graph_session.register_raw(json!({"name":name,"icon":"⋈", "inputs":[{"id":"join","name":"Wait for all branches","color":"#8ecaff"}],"outputs":[{"id":"combined","name":"Combined","color":"#89ddbd","icon":"✓","line_style":"solid"}]}),
    )?;
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut display = Display::new()?;
    let mut state = Round::default();
    let mut round = 1;
    let mut last_progress = Value::Null;
    while !STOP.load(Ordering::Relaxed) {
        if display.poll_input()? {
            break;
        }
        graph_session.heartbeat()?;
        let adjacent = rpc("graph.adjacent", json!({}))?;
        let batch = graph_session.take_raw()?;
        let accepted = state.ingest(
            wires(&adjacent),
            &batch,
        )?;
        state.update_titles(&adjacent);
        for event in accepted {
            display.log(
                &format!(
                    "IN · round {round} · {} → Join",
                    state.label(&Wire::event(&event))
                ),
                &event,
            );
        }
        let output_connected = adjacent["outgoing"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|v| v["from_port"] == "combined" && v["send"] == true && v["muted"] != true);
        let status = if state.expected.is_empty() {
            "Connect upstream Send or Turn completed outputs to Join."
        } else if state.complete() && !output_connected {
            "All arrived. Connect Combined to the next agent."
        } else if state.complete() {
            "All arrived. Forwarding combined output."
        } else {
            "Waiting for all branches. Ctrl+C to exit."
        };
        display.draw(&name, round, &state, status)?;
        let pending = json!({"round":round,"received":state.received.len(),"total":state.expected.len(),"waiting_for":state.expected.iter().filter(|wire| !state.received.contains_key(*wire)).map(|wire| json!({"node":wire.source,"port":wire.output,"title":state.titles.get(wire)})).collect::<Vec<_>>(),"output_connected":output_connected});
        if pending != last_progress {
            for event in state.received.values() {
                rpc(
                    "graph.progress",
                    json!({"event_id":event["event_id"],"message":status,"details":pending}),
                )?;
            }
            last_progress = pending;
        }
        if state.complete() && output_connected {
            // Keep the first branch's run budget, and preserve every branch's
            // original run_id in inputs. Independent Stop events have distinct IDs.
            let run_id = state.received.values().next().unwrap()["run_id"].clone();
            let output = json!({"output":"combined","run_id":run_id,"kind":"parallel.completed","sessions":state.received.values().flat_map(|event| event["sessions"].as_array().into_iter().flatten().cloned()).collect::<Vec<_>>(),"payload":state.payload(round)});
            let result = rpc("graph.emit", output.clone())?;
            if result["status"] != "queued" {
                return Err("Combined output was not queued; inputs remain pending".into());
            }
            display.output(&format!("OUT · round {round} · Combined · queued"), &output);
            // Never acknowledge a partial round. On any ambiguous transport failure
            // stop rather than automatically emitting the completed round twice.
            for event in state.received.values() {
                graph_session.ack(event["event_id"].as_str().ok_or("Host event has no ID")?)?;
            }
            display.draw(&name, round, &state, "Combined output queued.")?;
            if args.once {
                return Ok(());
            }
            round += 1;
            state = Round::default();
            continue;
        }
        // Animate and handle local view controls without increasing host polling.
        // Redirected output still logs only state changes and never reads stdin.
        let next_poll = Instant::now() + Duration::from_millis(300);
        while Instant::now() < next_poll && !STOP.load(Ordering::Relaxed) {
            let tick = Duration::from_millis(if display.animating() { 33 } else { 100 });
            std::thread::sleep(tick.min(next_poll.saturating_duration_since(Instant::now())));
            if display.poll_input()? {
                return Ok(());
            }
            display.draw(&name, round, &state, status)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn edge(source: &str) -> Value {
        json!({"from":source,"from_port":"turn_completed","to_port":"join","revision":1,"turn_completed":true})
    }
    fn event(source: &str, id: &str) -> Value {
        json!({"source":source,"source_port":"turn_completed","target_port":"join","edge_revision":1,"event_id":id,"run_id":format!("run-{id}"),"text":id,"sessions":[{"path":format!("/{source}.jsonl"),"checkpoint":{"byte_offset":42}}]})
    }
    #[test]
    fn waits_for_each_wire_and_keeps_first_event_for_next_round() {
        let edges = wires(&json!({"incoming":[edge("a"),edge("b")]}));
        let mut round = Round::default();
        let accepted = round
            .ingest(edges.clone(), &[event("a", "a1"), event("a", "a2")])
            .unwrap();
        assert_eq!(accepted, vec![event("a", "a1")]);
        assert!(!round.complete());
        let accepted = round
            .ingest(edges.clone(), &[event("a", "a1"), event("b", "b1")])
            .unwrap();
        assert_eq!(accepted, vec![event("b", "b1")]);
        assert!(
            round
                .ingest(edges.clone(), &[event("a", "a1"), event("b", "b1")])
                .unwrap()
                .is_empty()
        );
        assert!(round.complete());
        let payload = round.payload(1);
        assert_eq!(payload["inputs"][0]["event_id"], "a1");
        assert_eq!(payload["inputs"][1]["sessions"][0]["path"], "/b.jsonl");
        assert_eq!(
            payload["inputs"][1]["sessions"][0]["checkpoint"]["byte_offset"],
            42
        );
        let mut next = Round::default();
        assert_eq!(
            next.ingest(edges, &[event("a", "a2")]).unwrap(),
            vec![event("a", "a2")]
        );
    }
    #[test]
    fn ignores_read_and_muted_wires_and_refuses_mid_round_changes() {
        let edges = wires(
            &json!({"incoming":[edge("a"),{"from":"r","to_port":"join","read":true},{"from":"m","to_port":"join","send":true,"muted":true}]}),
        );
        assert_eq!(edges.len(), 1);
        let mut round = Round::default();
        assert!(!round.complete());
        round.ingest(edges, &[event("a", "a1")]).unwrap();
        assert!(round.ingest(vec![], &[]).is_err());
    }
}
