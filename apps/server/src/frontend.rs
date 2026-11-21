//! Bounded presentation RPC routing. Only authenticated private clients register.
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::mpsc::SyncSender,
    time::{Duration, Instant},
};

const MAX_PENDING: usize = 32;
const TIMEOUT: Duration = Duration::from_secs(32);

pub fn handles(method: &str) -> bool {
    matches!(
        method,
        "navigator.focus"
            | "identify"
            | "window.set_title"
            | "pane.list"
            | "pane.inspect"
            | "surface.list"
            | "chromium.list"
            | "tab.list"
            | "tab.set_title"
            | "chromium.select"
            | "chromium.present"
            | "chromium.create"
    ) || method.starts_with("tiling.")
}

/// Recovery checkpoints and terminal text capture are owned by the server.
pub fn handles_request(value:&Value)->bool {
    handles(value["method"].as_str().unwrap_or(""))
}

struct Pending {
    workspace: String,
    owner: u64,
    generation: u64,
    session: u64,
    api_id: Value,
    event: Option<Value>,
    reply: SyncSender<Value>,
    started: Instant,
}

#[derive(Default)]
pub struct Broker {
    owners: HashMap<String, VecDeque<u64>>,
    generations: HashMap<u64, u64>,
    pending: BTreeMap<u64, Pending>,
    sequence: u64,
}
impl Broker {
    pub fn has_owner(&self, workspace: &str) -> bool {
        self.owners
            .get(workspace)
            .is_some_and(|owners| !owners.is_empty())
    }
    pub fn register(&mut self, workspace: &str, client: u64, generation: u64) -> bool {
        if self
            .generations
            .get(&client)
            .is_some_and(|previous| *previous != generation)
        {
            self.disconnect(client);
        }
        self.generations.insert(client, generation);
        let owners = self.owners.entry(workspace.into()).or_default();
        if !owners.contains(&client) {
            owners.push_back(client);
        }
        owners.front() == Some(&client)
    }
    pub fn enqueue(
        &mut self,
        workspace: &str,
        session: u64,
        value: &Value,
        reply: SyncSender<Value>,
    ) -> Result<(), &'static str> {
        if self.pending.len() >= MAX_PENDING {
            return Err("Too many pending frontend requests");
        }
        let owner = self
            .owners
            .get(workspace)
            .and_then(|o| o.front())
            .copied()
            .ok_or("No local presentation frontend is connected")?;
        self.sequence += 1;
        let ticket = self.sequence;
        let generation = self.generations[&owner];
        self.pending.insert(ticket, Pending { workspace: workspace.into(), owner, generation, session, api_id: value["id"].clone(),
            event: Some(json!({"type":"frontend_request","ticket":ticket,"session":session,"generation":generation,
                "expires_unix_ms":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() + TIMEOUT.as_millis(),
                "method":value["method"],"params":value["params"]})), reply, started: Instant::now() });
        Ok(())
    }
    pub fn events(&mut self, workspace: &str, client: u64) -> Vec<Value> {
        self.pending
            .values_mut()
            .filter(|p| p.workspace == workspace && p.owner == client)
            .filter_map(|p| p.event.take())
            .take(8)
            .collect()
    }
    pub fn complete(
        &mut self,
        workspace: &str,
        client: u64,
        ticket: u64,
        response: &Value,
    ) -> Result<(), &'static str> {
        let pending = self
            .pending
            .get(&ticket)
            .ok_or("Unknown or expired frontend request")?;
        if pending.workspace != workspace || pending.owner != client {
            return Err("Frontend reply belongs to another presentation owner");
        }
        if self.generations.get(&client) != Some(&pending.generation) {
            return Err("Frontend activation has changed");
        }
        if !response.is_object()
            || (response.get("result").is_none() == response.get("error").is_none())
        {
            return Err("Expected exactly one frontend result or error");
        }
        let pending = self.pending.remove(&ticket).unwrap();
        Self::finish(pending, response.clone());
        Ok(())
    }
    fn finish(pending: Pending, mut response: Value) {
        response["id"] = pending.api_id;
        response["version"] = json!(1);
        let _ = pending.reply.try_send(response);
    }
    pub fn disconnect(&mut self, client: u64) {
        self.generations.remove(&client);
        for owners in self.owners.values_mut() {
            owners.retain(|id| *id != client);
        }
        self.owners.retain(|_, owners| !owners.is_empty());
        let canceled: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, p)| p.owner == client)
            .map(|(id, _)| *id)
            .collect();
        for id in canceled {
            Self::finish(
                self.pending.remove(&id).unwrap(),
                json!({"error":{"code":"frontend_closed","message":"Presentation frontend disconnected"}}),
            );
        }
    }
    pub fn expire(&mut self, mut live: impl FnMut(u64, &str) -> bool) {
        let expired: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, p)| p.started.elapsed() >= TIMEOUT || !live(p.session, &p.workspace))
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            Self::finish(
                self.pending.remove(&id).unwrap(),
                json!({"error":{"code":"frontend_timeout","message":"Calling terminal closed or frontend request timed out"}}),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    #[test]
    fn only_the_designated_workspace_owner_can_complete_an_authenticated_request() {
        let mut broker = Broker::default();
        assert!(broker.register("one", 10, 1));
        assert!(!broker.register("one", 11, 1));
        assert!(broker.register("two", 20, 1));
        let (tx, rx) = mpsc::sync_channel(1);
        broker
            .enqueue(
                "one",
                7,
                &json!({"id":"cli","method":"identify","params":{}}),
                tx,
            )
            .unwrap();
        assert!(broker.events("one", 11).is_empty());
        assert!(broker.events("two", 10).is_empty());
        let event = broker.events("one", 10).pop().unwrap();
        assert_eq!(event["session"], 7);
        assert!(broker.events("one", 10).is_empty());
        let ticket = event["ticket"].as_u64().unwrap();
        assert!(
            broker
                .complete("two", 20, ticket, &json!({"result":{}}))
                .is_err()
        );
        assert!(
            broker
                .complete("one", 11, ticket, &json!({"result":{}}))
                .is_err()
        );
        assert!(
            broker
                .complete("one", 10, ticket, &json!({"result":{},"error":{}}))
                .is_err()
        );
        broker
            .complete(
                "one",
                10,
                ticket,
                &json!({"result":{"pane":"%7"},"id":"forged"}),
            )
            .unwrap();
        let response = rx.try_recv().unwrap();
        assert_eq!(response["id"], "cli");
        assert_eq!(response["result"]["pane"], "%7");
        assert!(
            broker
                .complete("one", 10, ticket, &json!({"result":{}}))
                .is_err()
        );
    }
    #[test]
    fn queues_are_bounded_and_owner_disconnect_cancels_before_failover() {
        let mut broker = Broker::default();
        assert!(!broker.has_owner("one"));
        broker.register("one", 10, 1);
        broker.register("one", 11, 1);
        let mut receivers = vec![];
        for id in 0..MAX_PENDING {
            let (tx, rx) = mpsc::sync_channel(1);
            broker.enqueue("one", 7, &json!({"id":id}), tx).unwrap();
            receivers.push(rx);
        }
        let (tx, _) = mpsc::sync_channel(1);
        assert!(broker.enqueue("one", 7, &json!({}), tx).is_err());
        assert_eq!(broker.events("one", 10).len(), 8);
        broker.disconnect(10);
        assert!(broker.has_owner("one"));
        assert!(
            receivers
                .iter()
                .all(|rx| rx.try_recv().unwrap()["error"]["code"] == "frontend_closed")
        );
        let (tx, rx) = mpsc::sync_channel(1);
        broker.enqueue("one", 7, &json!({}), tx).unwrap();
        assert_eq!(broker.events("one", 11).len(), 1);
        broker.expire(|_, _| false);
        assert_eq!(rx.try_recv().unwrap()["error"]["code"], "frontend_timeout");
        broker.disconnect(11);
        assert!(!broker.has_owner("one"));
    }
    #[test]
    fn elapsed_requests_release_capacity_and_cannot_reply_later() {
        let mut broker = Broker::default();
        broker.register("one", 1, 1);
        let (tx, rx) = mpsc::sync_channel(1);
        broker.enqueue("one", 7, &json!({}), tx).unwrap();
        broker.pending.get_mut(&1).unwrap().started = Instant::now() - TIMEOUT;
        broker.expire(|_, _| true);
        assert_eq!(rx.try_recv().unwrap()["error"]["code"], "frontend_timeout");
        assert!(broker.events("one", 1).is_empty());
        assert!(broker.complete("one", 1, 1, &json!({"result":{}})).is_err());
    }
    #[test]
    fn reactivation_cancels_old_requests_and_changes_the_event_generation() {
        let mut broker = Broker::default();
        broker.register("one", 10, 1);
        let (tx, rx) = mpsc::sync_channel(1);
        broker.enqueue("one", 7, &json!({}), tx).unwrap();
        let stale = broker.events("one", 10).pop().unwrap();
        assert_eq!(stale["generation"], 1);
        broker.disconnect(10);
        assert_eq!(rx.try_recv().unwrap()["error"]["code"], "frontend_closed");
        broker.register("one", 10, 3);
        let (tx, _) = mpsc::sync_channel(1);
        broker.enqueue("one", 7, &json!({}), tx).unwrap();
        assert_eq!(broker.events("one", 10)[0]["generation"], 3);
        assert!(
            broker
                .complete(
                    "one",
                    10,
                    stale["ticket"].as_u64().unwrap(),
                    &json!({"result":{}})
                )
                .is_err()
        );
    }
}

#[cfg(test)]
mod capture_tests{
    #[test]
    fn tab_names_resolve_visible_positions_through_the_presentation_owner() {
        assert!(super::handles_request(&serde_json::json!({"method":"tab.set_title","params":{"position":2,"title":"Logs"}})));
        assert!(super::handles_request(&serde_json::json!({"method":"tab.list","params":{}})));
    }
    #[test]
    fn terminal_commands_never_depend_on_presentation_ownership() {
        for method in ["terminal.type", "terminal.press", "terminal.get_text", "terminal.pid"] {
            assert!(!super::handles_request(&serde_json::json!({"method":method,"params":{}})));
        }
    }
    #[test]
    fn session_capture_uses_the_server(){
        use serde_json::json;
        assert!(!super::handles_request(&json!({"method":"session.capture","params":{}})));
        assert!(!super::handles_request(&json!({"method":"session.capture","params":{"layout":false}})));
        assert!(!super::handles_request(&json!({"method":"session.capture","params":{"layout":true}})));
        assert!(super::handles_request(&json!({"method":"chromium.create","params":{}})));
    }
}
