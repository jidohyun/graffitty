//! Human-input quiet gate, following herdr-core's input::Gate/type_in:
//! c6b316f87c33e6f2ab1a1ceea3e3461e2b6bb61a (Apache-2.0).
//! Native agent APIs don't paste bytes, so they need the quiet gate, not
//! herdr's PTY paste/Enter interleaving buffer.
use std::time::{Duration, Instant};

pub const QUIET: Duration = Duration::from_secs(3);

#[derive(Default)]
pub struct Gate {
    last_human: Option<Instant>,
}
impl Gate {
    pub fn human(&mut self, now: Instant) { self.last_human = Some(now); }
    pub fn remaining(&self, now: Instant) -> Duration {
        self.last_human.map_or(Duration::ZERO, |last| QUIET.saturating_sub(now.saturating_duration_since(last)))
    }
    pub fn blocked(&self) -> bool { !self.remaining(Instant::now()).is_zero() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn waits_three_seconds_since_the_latest_human_input() {
        let now = Instant::now();
        let mut gate = Gate::default();
        assert!(gate.remaining(now).is_zero());
        gate.human(now);
        assert_eq!(gate.remaining(now + Duration::from_secs(2)), Duration::from_secs(1));
        gate.human(now + Duration::from_secs(2));
        assert_eq!(gate.remaining(now + Duration::from_secs(3)), Duration::from_secs(2));
        assert!(gate.remaining(now + Duration::from_secs(5)).is_zero());
    }
}
