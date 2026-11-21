//! Ephemeral clipboard routing. A request belongs to one subscribed frontend;
//! neither terminal checkpoints nor reconnects replay clipboard side effects.
use std::{collections::{BTreeSet, HashMap, VecDeque}, time::{Duration, Instant}};
use graffitty_protocol::clipboard::Operation;

#[derive(Default)]
pub struct Broker {
    viewers: BTreeSet<u64>,
    pub owner: Option<u64>,
    pub generation: u64,
    sequence: u64,
    queued: VecDeque<(u64, Operation)>,
    bytes: usize,
    pending: HashMap<u64, (Instant, usize)>,
}
impl Broker {
    pub fn subscribe(&mut self, client: u64, subscribed: bool) {
        if subscribed { self.viewers.insert(client); }
        else { self.viewers.remove(&client); }
        if self.owner.is_none() || self.owner.is_some_and(|id| !self.viewers.contains(&id)) {
            self.select(self.viewers.first().copied());
        }
    }
    fn select(&mut self, owner: Option<u64>) {
        if self.owner != owner { self.reset(); self.owner = owner; }
    }
    pub fn interact(&mut self, client: u64) {
        if self.viewers.contains(&client) { self.select(Some(client)); }
    }
    pub fn reset(&mut self) {
        self.generation += 1;
        self.queued.clear();
        self.pending.clear();
        self.bytes = 0;
    }
    pub fn push(&mut self, packet: Operation) {
        if self.owner.is_none() { return; }
        if self.pending.len() + self.queued.len() >= 256 || self.bytes + packet.payload_bytes() > 4 * 1024 * 1024 {
            // Never continue a partial write after dropping one of its chunks.
            self.reset();
            return;
        }
        self.sequence += 1;
        self.bytes += packet.payload_bytes();
        self.queued.push_back((self.sequence, packet));
    }
    pub fn take(&mut self, client: u64) -> Vec<(u64, Operation)> {
        if self.owner != Some(client) { return vec![]; }
        if self.pending.values().any(|(at, _)| at.elapsed() > Duration::from_secs(90)) { self.reset(); }
        let packets: Vec<_> = self.queued.drain(..).collect();
        self.bytes = 0;
        for (id, _) in &packets { self.pending.insert(*id, (Instant::now(), 0)); }
        packets
    }
    pub fn reply(&mut self, client: u64, generation: u64, ticket: u64, offset: usize, len: usize, done: bool) -> Result<(), &'static str> {
        if self.owner != Some(client) || generation != self.generation { return Err("Stale clipboard owner"); }
        let Some((at, received)) = self.pending.get_mut(&ticket) else { return Err("Unknown clipboard request"); };
        if at.elapsed() > Duration::from_secs(90) || *received != offset || len > 48 * 1024 || offset + len > 96 * 1024 * 1024 {
            return Err("Invalid clipboard reply");
        }
        *received += len;
        if done { self.pending.remove(&ticket); }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_is_single_owner_and_never_replayed() {
        let mut b = Broker::default();
        b.subscribe(1, true); b.subscribe(2, true);
        b.push(Operation::Rich { packet: "read".into() });
        assert!(b.take(2).is_empty());
        let ticket = b.take(1)[0].0;
        let generation = b.generation;
        assert!(b.reply(2, generation, ticket, 0, 1, true).is_err());
        b.interact(2);
        assert!(b.reply(1, generation, ticket, 0, 1, true).is_err());
        assert!(b.take(2).is_empty());
        b.push(Operation::Rich { packet: "read".into() });
        let ticket = b.take(2)[0].0;
        assert!(b.reply(2, b.generation, ticket, 0, 4, false).is_ok());
        assert!(b.reply(2, b.generation, ticket, 0, 4, false).is_err());
        assert!(b.reply(2, b.generation, ticket, 4, 1, true).is_ok());
        assert!(b.reply(2, b.generation, ticket, 5, 0, true).is_err());
        b.subscribe(2, false);
        assert_eq!(b.owner, Some(1));
    }
    #[test]
    fn reset_and_overflow_revoke_pending_requests() {
        let mut b = Broker::default(); b.subscribe(1, true);
        b.push(Operation::Rich { packet: "read".into() }); let ticket = b.take(1)[0].0; let generation = b.generation;
        b.reset();
        assert!(b.reply(1, generation, ticket, 0, 0, true).is_err());
        for _ in 0..257 { b.push(Operation::Rich { packet: "chunk".into() }); }
        assert!(b.take(1).is_empty());
        b.subscribe(1, false); b.push(Operation::Rich { packet: "read".into() }); b.subscribe(2, true);
        assert!(b.take(2).is_empty());
    }
}
