//! Pane claims (OSC 4723) bind a process to the pane that displays it.
//! Use them when inherited pane capabilities can point elsewhere, as in tmux.
//!
//! 1. Call `pane.claim.begin` to get a nonce and a private ticket. Use
//!    any live pane capability, including the one tmux inherited. If that pane
//!    has closed, use the local server capability.
//! 2. Print the nonce as OSC 4723. The terminal that displays it reports it.
//! 3. Call `pane.claim.finish` with the ticket. It waits for the report and
//!    returns the displaying pane's capability.
//!
//! A capability used to start a claim only authorizes step 1. If two panes
//! display the nonce, the claim fails. This can happen when two Graffitty
//! panes are attached to the same tmux session.
//!
//! See `docs/developers/automation-and-extensions/pane-claim.md`.
use crate::{Error, Server, api};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::time::{Duration, Instant};

/// How long a claim waits for its nonce to appear in a terminal.
pub const TIMEOUT: Duration = Duration::from_secs(2);
/// After the first sighting, how long a second attached pane may still show it.
const SETTLE: Duration = Duration::from_millis(50);
/// Unfinished claims a process may hold at once across the server.
const MAX_PENDING: usize = 64;

pub fn handles(method: &str) -> bool {
    matches!(method, "pane.claim.begin" | "pane.claim.finish")
}

pub fn dispatch(server: &mut Server, request: &Value) -> Result<api::Reply, Error> {
    let (_, method, params) = api::request(request, |token| {
        (token == server.local_token || server.sessions.values().any(|s| s.token == token)).then_some(0)
    })?;
    let now = Instant::now();
    if method == "pane.claim.begin" {
        let (nonce, ticket) = server.pane_claims.begin(now)?;
        return Ok(api::Reply::Ready(json!({"result":{
            "nonce":nonce,"ticket":ticket,"timeout_ms":TIMEOUT.as_millis() as u64}})));
    }
    let ticket = params["ticket"].as_str().ok_or_else(|| api::error("invalid_params", "Expected claim ticket"))?;
    server.pane_claims.finish(ticket).map(api::Reply::Pending)
}

/// Match nonces the terminals printed, then answer every claim that is decided.
pub fn poll(server: &mut Server) {
    let now = Instant::now();
    for session in server.sessions.values() {
        for nonce in session.claim_nonces.take() {
            server.pane_claims.observe(session.id, &nonce, now);
        }
    }
    let sessions = &server.sessions;
    server.pane_claims.settle(now, |id| {
        sessions.get(&id).filter(|s| !s.exited).map(|s| s.token.clone())
    });
}

#[derive(Default)]
pub struct Claims {
    pending: HashMap<String, Claim>,
}

struct Claim {
    ticket: String,
    issued: Instant,
    seen: Vec<u64>,
    first_seen: Option<Instant>,
    waiter: Option<SyncSender<Value>>,
}

impl Claims {
    pub fn begin(&mut self, now: Instant) -> Result<(String, String), Error> {
        self.pending.retain(|_, claim| now - claim.issued < TIMEOUT * 2);
        if self.pending.len() >= MAX_PENDING {
            return Err(api::error("busy", "Too many pane claims in progress; retry shortly"));
        }
        let nonce = uuid::Uuid::new_v4().simple().to_string();
        let ticket = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
        debug_assert!(graffitty_protocol::osc::valid_nonce(&nonce));
        self.pending.insert(nonce.clone(), Claim {
            ticket: ticket.clone(), issued: now, seen: vec![], first_seen: None, waiter: None,
        });
        Ok((nonce, ticket))
    }

    pub fn observe(&mut self, pane: u64, nonce: &str, now: Instant) {
        let Some(claim) = self.pending.get_mut(nonce).filter(|c| now - c.issued < TIMEOUT) else { return };
        if !claim.seen.contains(&pane) {
            claim.seen.push(pane);
        }
        claim.first_seen.get_or_insert(now);
    }

    pub fn finish(&mut self, ticket: &str) -> Result<Receiver<Value>, Error> {
        let claim = self.pending.values_mut()
            .find(|c| c.ticket == ticket && c.waiter.is_none())
            .ok_or_else(|| api::error("invalid_claim", "Unknown or already finished pane claim"))?;
        let (sender, receiver) = sync_channel(1);
        claim.waiter = Some(sender);
        Ok(receiver)
    }

    /// Answer decided claims. `token` gives a live pane's capability.
    pub fn settle(&mut self, now: Instant, token: impl Fn(u64) -> Option<String>) {
        self.pending.retain(|_, claim| {
            let Some(waiter) = &claim.waiter else {
                return now - claim.issued < TIMEOUT * 2;
            };
            let reply = match claim.first_seen {
                Some(first) if now - first >= SETTLE => Some(match claim.seen.as_slice() {
                    [pane] => match token(*pane) {
                        Some(token) => json!({"result":{"pane":format!("%{pane}"),"token":token}}),
                        None => failure("pane_closed", "The claiming pane closed"),
                    },
                    panes => failure("ambiguous_claim", &format!(
                        "The claim appeared in several Graffitty panes ({}); attach this tmux session from only one",
                        panes.iter().map(|p| format!("%{p}")).collect::<Vec<_>>().join(", "))),
                }),
                None if now - claim.issued >= TIMEOUT => Some(failure("claim_timeout",
                    "No Graffitty pane displayed the claim; enable tmux passthrough with `set -g allow-passthrough all`")),
                _ => None,
            };
            match reply {
                Some(reply) => { let _ = waiter.try_send(reply); false }
                None => true,
            }
        });
    }
}

fn failure(code: &str, message: &str) -> Value {
    json!({"error":{"code":code,"message":message}})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(id: u64) -> Option<String> { (id != 9).then(|| format!("token-{id}")) }

    #[test]
    fn a_nonce_seen_in_one_pane_returns_that_panes_capability_after_settling() {
        let mut claims = Claims::default();
        let start = Instant::now();
        let (nonce, ticket) = claims.begin(start).unwrap();
        let reply = claims.finish(&ticket).unwrap();
        claims.observe(3, &nonce, start);
        claims.observe(3, &nonce, start);
        claims.settle(start + SETTLE / 2, token);
        assert!(reply.try_recv().is_err(), "a second attached pane may still report it");
        claims.settle(start + SETTLE, token);
        assert_eq!(reply.try_recv().unwrap(), json!({"result":{"pane":"%3","token":"token-3"}}));
        assert!(claims.finish(&ticket).is_err(), "tickets are single use");
    }

    #[test]
    fn ambiguous_unseen_closed_and_unknown_claims_fail() {
        let mut claims = Claims::default();
        let start = Instant::now();
        let (nonce, ticket) = claims.begin(start).unwrap();
        let both = claims.finish(&ticket).unwrap();
        claims.observe(1, &nonce, start);
        claims.observe(2, &nonce, start);
        let (_, ticket) = claims.begin(start).unwrap();
        let unseen = claims.finish(&ticket).unwrap();
        let (closed_nonce, ticket) = claims.begin(start).unwrap();
        let closed = claims.finish(&ticket).unwrap();
        claims.observe(9, &closed_nonce, start);
        claims.settle(start + TIMEOUT, token);
        assert_eq!(both.try_recv().unwrap()["error"]["code"], "ambiguous_claim");
        assert_eq!(unseen.try_recv().unwrap()["error"]["code"], "claim_timeout");
        assert_eq!(closed.try_recv().unwrap()["error"]["code"], "pane_closed");
        assert!(claims.finish("forged").is_err());
    }

    #[test]
    fn late_sightings_are_ignored_and_abandoned_claims_expire() {
        let mut claims = Claims::default();
        let start = Instant::now();
        let (nonce, ticket) = claims.begin(start).unwrap();
        let reply = claims.finish(&ticket).unwrap();
        claims.observe(3, &nonce, start + TIMEOUT);
        claims.settle(start + TIMEOUT + SETTLE, token);
        assert_eq!(reply.try_recv().unwrap()["error"]["code"], "claim_timeout");
        claims.begin(start).unwrap();
        claims.settle(start + TIMEOUT * 2, token);
        assert!(claims.pending.is_empty());
        for _ in 0..MAX_PENDING { claims.begin(start).unwrap(); }
        assert!(claims.begin(start).is_err());
    }
}
