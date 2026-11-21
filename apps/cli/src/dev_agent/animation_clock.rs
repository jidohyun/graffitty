//! Optional capture clock: terminal animation follows video time, not encoder speed.
use std::{path::PathBuf, time::Instant};

pub(super) struct AnimationClock {
    path: Option<PathBuf>,
    turn: Option<Instant>,
    start: u64,
    last: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slow_encoder_and_transient_missing_frame_do_not_speed_up_animation() {
        let path = std::env::temp_dir().join(format!("gft-animation-clock-{}", std::process::id()));
        std::fs::write(&path, "10000").unwrap();
        let mut clock = AnimationClock::new(Some(path.clone()));
        let turn = Some(Instant::now());
        assert_eq!(clock.elapsed(turn, 0), 0);
        std::fs::write(&path, "10120").unwrap();
        assert_eq!(clock.elapsed(turn, 900), 120);
        std::fs::remove_file(&path).unwrap();
        assert_eq!(clock.elapsed(turn, 1200), 120);
        assert_eq!(clock.elapsed(None, 0), 0);
        assert_eq!(AnimationClock::new(None).elapsed(turn, 345), 345);
    }
}

impl AnimationClock {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            turn: None,
            start: 0,
            last: 0,
        }
    }

    pub fn elapsed(&mut self, turn: Option<Instant>, wall_elapsed: u64) -> u64 {
        let Some(path) = &self.path else {
            return wall_elapsed;
        };
        if let Ok(value) = std::fs::read_to_string(path)
            .unwrap_or_default()
            .trim()
            .parse::<u64>()
        {
            self.last = self.last.max(value);
        }
        if self.turn != turn {
            self.turn = turn;
            self.start = self.last;
        }
        self.last.saturating_sub(self.start)
    }
}
