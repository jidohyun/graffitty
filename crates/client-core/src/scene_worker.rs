//! Bounded background preparation; no UI/framework objects cross this boundary.
use crate::{
    mirror::Update,
    scene::{Assets, Commit, Pixels, Replica},
};
use graffitty_protocol::{
    SessionId,
    terminal_scene::{AssetChunk, Transaction},
};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
        mpsc::{self, SyncSender, TrySendError},
    },
};

pub enum Job {
    Terminal(SessionId, Update, Transaction, Vec<u8>),
    Asset(SessionId, AssetChunk, Vec<u8>),
}
pub enum Prepared {
    Terminal(SessionId, Commit),
    Asset(SessionId, Pixels),
    Error(SessionId, String),
}
pub struct Worker {
    input: SyncSender<Job>,
    pub output: crate::scene_mailbox::Receiver,
    pending: Option<Job>,
    pub(crate) in_flight: Arc<AtomicUsize>,
    pub(crate) ready: Arc<AtomicUsize>,
}
impl Default for Worker {
    fn default() -> Self {
        let (input, jobs) = mpsc::sync_channel(32);
        let in_flight = Arc::new(AtomicUsize::new(0));
        let count = in_flight.clone();
        let ready = Arc::new(AtomicUsize::new(0));
        let (results, output) = crate::scene_mailbox::channel(ready.clone());
        std::thread::Builder::new()
            .name("terminal-replica".into())
            .spawn(move || {
                let mut replicas: BTreeMap<SessionId, Replica> = BTreeMap::new();
                let mut assets = Assets::default();
                while let Ok(job) = jobs.recv() {
                    let (session, result) = match job {
                        Job::Terminal(id, update, tx, bytes) => (
                            id,
                            replicas
                                .entry(id)
                                .or_default()
                                .push(update, tx, &bytes)
                                .map(|v| v.map(|v| Prepared::Terminal(id, v))),
                        ),
                        Job::Asset(id, chunk, bytes) => (
                            id,
                            assets
                                .push(chunk, &bytes)
                                .map(|v| v.map(|v| Prepared::Asset(id, v))),
                        ),
                    };
                    let next = match result {
                        Ok(next) => next,
                        Err(error) => {
                            replicas.remove(&session);
                            Some(Prepared::Error(session, error.to_string()))
                        }
                    };
                    if let Some(next) = next {
                        if results.send(next).is_err() {
                            break;
                        }
                    }
                    count.fetch_sub(1, Ordering::Release);
                }
                count.store(0, Ordering::Release);
            })
            .expect("Start terminal replica worker");
        Self {
            input,
            output,
            pending: None,
            in_flight,
            ready,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prepared_but_undelivered_result_holds_credit() {
        let mut worker = Worker::default();
        assert!(worker.submit(Job::Terminal(SessionId(1), Update {
            columns: 0, rows: 24, reset: false, exited: false, limits: Default::default(),
        }, Transaction {
            revision: 1, base: 0, snapshot: true, replace: true, offset: 0,
            total: 0, commit: true, graphics_bytes: 0,
        }, Vec::new())));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while worker.in_flight.load(Ordering::Acquire) != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(!worker.idle(), "Preparation alone must not release credits");
        assert!(matches!(worker.output.try_recv(), Ok(Prepared::Error(_, _))));
        assert!(worker.idle());
    }
}

impl Worker {
    /// Credit is returned only after preparation AND UI delivery. A decoder
    /// with a full presentation mailbox is not idle, even if input is empty.
    pub fn idle(&self) -> bool {
        self.pending.is_none()
            && self.in_flight.load(Ordering::Acquire) == 0
            && self.ready.load(Ordering::Acquire) == 0
    }
    pub fn flush(&mut self) -> bool {
        let Some(job) = self.pending.take() else {
            return true;
        };
        self.submit(job)
    }
    pub fn submit(&mut self, job: Job) -> bool {
        assert!(
            self.pending.is_none(),
            "Flush backpressure before submitting another packet"
        );
        self.in_flight.fetch_add(1, Ordering::Release);
        match self.input.try_send(job) {
            Ok(()) => true,
            Err(TrySendError::Full(job)) => {
                self.in_flight.fetch_sub(1, Ordering::Release);
                self.pending = Some(job);
                false
            }
            Err(TrySendError::Disconnected(_)) => {
                self.in_flight.fetch_sub(1, Ordering::Release);
                false
            }
        }
    }
}
