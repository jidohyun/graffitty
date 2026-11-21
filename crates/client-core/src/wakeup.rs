//! Window wakeups carry no UI objects or terminal state across threads.
use std::sync::{Arc, Weak, atomic::{AtomicBool, AtomicUsize, AtomicU64, Ordering}};
use std::time::{Duration, Instant};

pub struct Wakeup {
    pub(crate) transport: crate::transport::Readiness,
    pub(crate) pending: Arc<AtomicBool>,
    pub(crate) controller_pending: Arc<AtomicBool>,
    pub(crate) preparing: Arc<AtomicUsize>,
    pub(crate) prepared: Arc<AtomicUsize>,
    pub(crate) revision: Arc<AtomicU64>,
    /// Extra readiness sources outside the socket (chromium GPU mailboxes).
    pub(crate) probes: std::sync::Mutex<Vec<Arc<dyn Fn() -> bool + Send + Sync>>>,
}
impl Wakeup {
    pub fn is_ready(&self) -> bool {
        self.pending.load(Ordering::Acquire)
            || self.controller_pending.load(Ordering::Acquire)
            || self.preparing.load(Ordering::Acquire) != 0
            || self.prepared.load(Ordering::Acquire) != 0
            || self.transport.is_ready()
            || self.probes.lock().is_ok_and(|probes| probes.iter().any(|probe| probe()))
    }
    /// Wake windows when `probe` reports work; probing must not consume it.
    pub fn add_probe(&self, probe: Arc<dyn Fn() -> bool + Send + Sync>) {
        if let Ok(mut probes) = self.probes.lock() { probes.push(probe); }
    }
    /// Coalesce a burst into one event. The UI rearms after draining its frame;
    /// readiness is level-triggered, so arrivals during that frame cannot vanish.
    pub fn subscribe(self: &Arc<Self>, wake: impl Fn() + Send + 'static) -> std::io::Result<Subscription> {
        let source = Arc::downgrade(self);
        let control = Arc::new(Control::default());
        control.revision.store(self.revision.load(Ordering::Acquire), Ordering::Release);
        let state = control.clone();
        let watched = source.clone();
        std::thread::Builder::new().name("window-wakeup".into()).spawn(move || {
            while !state.stop.load(Ordering::Acquire) {
                let Some(source) = watched.upgrade() else { break };
                let current = source.revision.load(Ordering::Acquire);
                if !state.notified.load(Ordering::Acquire)
                    && Instant::now() >= *state.not_before.lock().unwrap()
                    && (source.is_ready() || state.revision.load(Ordering::Acquire) != current)
                    && !state.notified.swap(true, Ordering::AcqRel) { state.revision.store(current, Ordering::Release); wake(); }
                drop(source);
                // Probe readiness without scheduling a UI frame or consuming
                // bytes. This bounds both input latency and idle CPU work.
                std::thread::sleep(Duration::from_millis(8));
            }
        })?;
        Ok(Subscription { source, control })
    }
}
struct Control { revision: AtomicU64, stop: AtomicBool, notified: AtomicBool, not_before: std::sync::Mutex<Instant> }
impl Default for Control {
    fn default() -> Self { Self { revision: AtomicU64::new(0), stop: AtomicBool::new(false), notified: AtomicBool::new(false),
        not_before: std::sync::Mutex::new(Instant::now()) } }
}
pub struct Subscription { source: Weak<Wakeup>, control: Arc<Control> }
impl Subscription {
    pub fn matches(&self, source: &Arc<Wakeup>) -> bool {
        self.source.ptr_eq(&Arc::downgrade(source))
    }
    pub fn rearm(&self) { self.rearm_after(Duration::ZERO); }
    pub fn rearm_after(&self, delay: Duration) {
        // This window already consumed the current revision. Other windows
        // retain their own revision and still wake for shared state changes.
        if let Some(source) = self.source.upgrade() {
            self.control.revision.store(source.revision.load(Ordering::Acquire), Ordering::Release);
        }
        *self.control.not_before.lock().unwrap() = Instant::now() + delay;
        self.control.notified.store(false, Ordering::Release);
    }
}
impl Drop for Subscription {
    fn drop(&mut self) { self.control.stop.store(true, Ordering::Release); }
}
