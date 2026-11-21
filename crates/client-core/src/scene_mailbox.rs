//! Bounded presentation mailbox. Complete snapshots supersede unconsumed
//! terminal states; ordered assets/errors are never discarded as visual frames.
use crate::scene_worker::Prepared;
use std::{
    collections::VecDeque,
    sync::{Arc, Condvar, Mutex, atomic::{AtomicUsize, Ordering}, mpsc::TryRecvError},
};

const CAPACITY: usize = 32;
struct State {
    queue: VecDeque<Prepared>,
    closed: bool,
}
struct Shared {
    state: Mutex<State>,
    space: Condvar,
    ready: Arc<AtomicUsize>,
}
pub(crate) struct Sender(Arc<Shared>);
pub struct Receiver(Arc<Shared>);

pub(crate) fn channel(ready: Arc<AtomicUsize>) -> (Sender, Receiver) {
    let shared = Arc::new(Shared {
        state: Mutex::new(State { queue: VecDeque::new(), closed: false }),
        space: Condvar::new(),
        ready,
    });
    (Sender(shared.clone()), Receiver(shared))
}
impl Sender {
    pub(crate) fn send(&self, mut next: Prepared) -> Result<(), ()> {
        let mut state = self.0.state.lock().unwrap();
        if state.closed { return Err(()); }
        if let Prepared::Terminal(id, commit) = &mut next {
            if commit.terminal.is_none() {
                // Assets for this or other panes do not break VT ordering.
                // Errors do: the consumer must observe the resync boundary.
                for previous in state.queue.iter_mut().rev() {
                    match previous {
                        Prepared::Error(other, _) if other == id => break,
                        Prepared::Terminal(other, old) if other == id => {
                            if old.fold_delta(commit) { return Ok(()); }
                            break;
                        }
                        _ => {}
                    }
                }
            }
            // An error is a resync boundary. Do not erase states on the other
            // side of it, even if the next snapshot has already arrived.
            if commit.terminal.is_some() {
                let boundary = state.queue.iter().rposition(|p| matches!(p, Prepared::Error(other, _) if other == id))
                    .map_or(0, |i| i + 1);
                let before = state.queue.len();
                let mut index = 0;
                state.queue.retain(|p| {
                    let keep = index < boundary || !matches!(p, Prepared::Terminal(other, _) if other == id);
                    index += 1;
                    keep
                });
                self.0.ready.fetch_sub(before - state.queue.len(), Ordering::AcqRel);
            }
        }
        while state.queue.len() >= CAPACITY && !state.closed {
            state = self.0.space.wait(state).unwrap();
        }
        if state.closed { return Err(()); }
        state.queue.push_back(next);
        self.0.ready.fetch_add(1, Ordering::Release);
        Ok(())
    }
}
impl Drop for Sender {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().closed = true;
    }
}
impl Receiver {
    pub fn try_recv(&self) -> Result<Prepared, TryRecvError> {
        // Never stall the render thread behind producer-side reclamation.
        let Ok(mut state) = self.0.state.try_lock() else { return Err(TryRecvError::Empty); };
        if let Some(next) = state.queue.pop_front() {
            self.0.ready.fetch_sub(1, Ordering::AcqRel);
            self.0.space.notify_one();
            Ok(next)
        } else if state.closed {
            Err(TryRecvError::Disconnected)
        } else {
            Err(TryRecvError::Empty)
        }
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().closed = true;
        self.0.space.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{mirror::Update, scene::Replica};
    use graffitty_protocol::{SessionId, terminal_scene::Transaction};

    fn snapshot(id: u64, revision: u64) -> Prepared {
        let mut replica = Replica::default();
        let update = Update { columns: 80, rows: 24, reset: false, exited: false, limits: Default::default() };
        let tx = Transaction { revision, base: 0, snapshot: true, replace: true, offset: 0, total: 1, commit: true, graphics_bytes: 0 };
        Prepared::Terminal(SessionId(id), replica.push(update, tx, b"x").unwrap().unwrap())
    }

    #[test]
    fn stalled_consumer_keeps_only_latest_snapshot_per_terminal() {
        let ready = Arc::new(AtomicUsize::new(0));
        let (sender, receiver) = channel(ready.clone());
        for revision in 1..=1000 {
            sender.send(snapshot(1, revision)).unwrap();
            sender.send(snapshot(2, revision)).unwrap();
        }
        assert_eq!(ready.load(Ordering::Acquire), 2);
        for id in [1, 2] {
            let Prepared::Terminal(session, commit) = receiver.try_recv().unwrap() else { panic!() };
            assert_eq!(session, SessionId(id));
            assert_eq!(commit.revision, 1000);
        }
        assert_eq!(ready.load(Ordering::Acquire), 0);
    }

    #[test]
    fn deltas_fold_into_pending_snapshot_without_an_extra_ui_commit() {
        let ready = Arc::new(AtomicUsize::new(0));
        let (sender, receiver) = channel(ready.clone());
        sender.send(snapshot(1, 1)).unwrap();
        let mut replica = Replica::default();
        let update = Update { columns: 80, rows: 24, reset: false, exited: false, limits: Default::default() };
        replica.push(update.clone(), Transaction { revision: 1, base: 0, snapshot: true, replace: true, offset: 0, total: 1, commit: true, graphics_bytes: 0 }, b"x").unwrap();
        for revision in 2..=100 {
            let commit = replica.push(update.clone(), Transaction {
                revision, base: revision - 1, snapshot: false, replace: false,
                offset: 0, total: 7, commit: true, graphics_bytes: 0,
            }, b"\x1b[Hdone").unwrap().unwrap();
            sender.send(Prepared::Terminal(SessionId(1), commit)).unwrap();
        }
        assert_eq!(ready.load(Ordering::Acquire), 1);
        let Prepared::Terminal(_, commit) = receiver.try_recv().unwrap() else { panic!() };
        assert_eq!(commit.revision, 100);
        assert!(commit.text.is_empty());
        let mut mirror = crate::mirror::Mirror::new(80, 24, (10, 22), Default::default()).unwrap();
        mirror.apply_scene(commit).unwrap();
        assert!(mirror.text(false).unwrap().starts_with("done"));
        assert_eq!(mirror.vt.cursor_x().unwrap(), 4);
    }

    #[test]
    fn error_boundaries_are_not_lost() {
        let (sender, receiver) = channel(Default::default());
        sender.send(snapshot(1, 1)).unwrap();
        sender.send(Prepared::Error(SessionId(1), "resync".into())).unwrap();
        sender.send(snapshot(1, 2)).unwrap();
        sender.send(snapshot(1, 3)).unwrap();
        assert!(matches!(receiver.try_recv(), Ok(Prepared::Terminal(_, c)) if c.revision == 1));
        assert!(matches!(receiver.try_recv(), Ok(Prepared::Error(_, _))));
        assert!(matches!(receiver.try_recv(), Ok(Prepared::Terminal(_, c)) if c.revision == 3));
    }

    #[test]
    fn snapshot_replacement_keeps_image_assets() {
        let (sender, receiver) = channel(Default::default());
        sender.send(snapshot(1, 1)).unwrap();
        sender.send(Prepared::Asset(SessionId(1), crate::scene::Pixels {
            key: graffitty_protocol::terminal_scene::AssetKey("a".repeat(64)),
            width: 1, height: 1, rgba: vec![1, 2, 3, 255].into(),
        })).unwrap();
        sender.send(snapshot(1, 2)).unwrap();
        assert!(matches!(receiver.try_recv(), Ok(Prepared::Asset(_, _))));
        assert!(matches!(receiver.try_recv(), Ok(Prepared::Terminal(_, c)) if c.revision == 2));
    }

    #[test]
    fn dropping_receiver_unblocks_a_full_producer() {
        let (sender, receiver) = channel(Default::default());
        for _ in 0..CAPACITY { sender.send(Prepared::Error(SessionId(1), "test".into())).unwrap(); }
        let thread = std::thread::spawn(move || sender.send(Prepared::Error(SessionId(1), "test".into())));
        drop(receiver);
        assert!(thread.join().unwrap().is_err());
    }
}
