//! A stop is a sample position on the capture clock, never the first empty read.
use crate::{FRAME, RATE, Result};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub const DRAIN_NS: u64 = 250_000_000;

#[derive(Default)]
pub struct Control {
    stop_at: AtomicU64,
    canceled: AtomicBool,
}
impl Control {
    pub fn stop(&self, at: u64) {
        let _ = self
            .stop_at
            .compare_exchange(0, at.max(1), Ordering::AcqRel, Ordering::Acquire);
    }
    pub fn cancel(&self) {
        self.canceled.store(true, Ordering::Release);
    }
    pub fn is_stopping(&self) -> bool {
        self.stop_at.load(Ordering::Acquire) != 0
    }
    pub fn is_canceled(&self) -> bool {
        self.canceled.load(Ordering::Acquire)
    }
}

#[derive(Clone, Copy)]
pub struct Timestamp {
    pub frame: u64,
    pub nanos: u64,
}
impl Timestamp {
    fn frame_at(self, at: u64) -> u64 {
        (self.frame as i128
            + ((at as i128 - self.nanos as i128) * RATE as i128).div_euclid(1_000_000_000))
        .max(0) as u64
    }
}

pub trait Source {
    fn now(&self) -> u64;
    fn read(&mut self, samples: &mut [i16]) -> Result<usize>;
    fn timestamp(&self) -> Option<Timestamp>;
    fn idle(&mut self);
}

#[derive(Clone, Debug, Default)]
pub struct Drain {
    pub target: u64,
    pub delivered: u64,
    pub timestamped: bool,
    pub waited_ns: u64,
}

/// Caller owns the source and releases it only after this returns. The final emit
/// precedes completion; cancel emits no buffered data. All queues must be bounded.
pub fn run(
    source: &mut impl Source,
    started_at: u64,
    control: &Control,
    mut emit: impl FnMut(&[i16]) -> Result<()>,
) -> Result<Option<Drain>> {
    let mut frame = [0i16; FRAME];
    let mut used = 0;
    let mut delivered = 0u64;
    let mut target = None;
    let mut timestamped = false;
    let mut draining_at = None;
    loop {
        if control.canceled.load(Ordering::Acquire) {
            return Ok(None);
        }
        let stop_at = control.stop_at.load(Ordering::Acquire);
        if stop_at != 0 {
            draining_at.get_or_insert(source.now());
            if !timestamped {
                if let Some(stamp) = source.timestamp() {
                    target = Some(stamp.frame_at(stop_at));
                    timestamped = true;
                } else if target.is_none() {
                    target = Some(
                        Timestamp {
                            frame: 0,
                            nanos: started_at,
                        }
                        .frame_at(stop_at),
                    );
                }
            }
            used = used.min(target.unwrap().saturating_sub(delivered) as usize);
        }
        if used == FRAME {
            emit(&frame)?;
            delivered += used as u64;
            used = 0;
        }
        let limit = (FRAME - used).min(target.map_or(usize::MAX, |n| {
            n.saturating_sub(delivered + used as u64) as usize
        }));
        if limit == 0 || draining_at.is_some_and(|at| source.now().saturating_sub(at) >= DRAIN_NS) {
            break;
        }
        if delivered == 0 && used == 0 && source.now().saturating_sub(started_at) > 5_000_000_000 {
            return Err(
                "No audio arrived from the microphone. Check its permission and input device."
                    .into(),
            );
        }
        if delivered >= (RATE * 600) as u64 {
            control.stop(source.now());
            continue;
        }
        let count = source.read(&mut frame[used..used + limit])?;
        if count > limit {
            return Err("Microphone returned an invalid frame size".into());
        }
        used += count;
        // Re-check a release that happened during read before emitting this frame.
        let release = control.stop_at.load(Ordering::Acquire);
        if release != 0 && stop_at == 0 {
            continue;
        }
        if control.canceled.load(Ordering::Acquire) {
            return Ok(None);
        }
        if count == 0 {
            source.idle();
        }
    }
    if control.canceled.load(Ordering::Acquire) {
        return Ok(None);
    }
    if used != 0 {
        emit(&frame[..used])?;
        delivered += used as u64;
    }
    let drain = Drain {
        target: target.unwrap_or(delivered),
        delivered,
        timestamped,
        waited_ns: source
            .now()
            .saturating_sub(draining_at.unwrap_or(source.now())),
    };
    if delivered < drain.target {
        return Err(
            "Microphone did not deliver all audio through the stop time. Review the transcript."
                .into(),
        );
    }
    Ok(Some(drain))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn permission_wait_can_observe_stop_or_cancel_before_a_device_opens() {
        let stopped = Control::default();
        assert!(!stopped.is_stopping() && !stopped.is_canceled());
        stopped.stop(0);
        assert!(stopped.is_stopping());
        stopped.stop(99);
        assert_eq!(stopped.stop_at.load(Ordering::Acquire), 1);
        let canceled = Control::default();
        canceled.cancel();
        assert!(canceled.is_canceled());
        assert!(!canceled.is_stopping());
    }

    struct Fake {
        clock: u64,
        ready_at: u64,
        samples: Vec<i16>,
        offset: usize,
        stamp: Option<Timestamp>,
        control: Arc<Control>,
        stop_in_read: bool,
    }
    impl Source for Fake {
        fn now(&self) -> u64 {
            self.clock
        }
        fn timestamp(&self) -> Option<Timestamp> {
            self.stamp
        }
        fn idle(&mut self) {
            self.clock += 5_000_000;
        }
        fn read(&mut self, out: &mut [i16]) -> Result<usize> {
            if self.stop_in_read {
                self.control.stop(1_000_000_000);
            }
            let available = if self.clock < self.ready_at {
                960
            } else {
                self.samples.len()
            };
            let count = out.len().min(available.saturating_sub(self.offset));
            out[..count].copy_from_slice(&self.samples[self.offset..self.offset + count]);
            self.offset += count;
            Ok(count)
        }
    }
    fn fake() -> Fake {
        Fake {
            clock: 1_000_000_000,
            ready_at: 1_100_000_000,
            samples: (0..7000).map(|n| n as i16).collect(),
            offset: 0,
            stamp: Some(Timestamp {
                frame: 6017,
                nanos: 1_025_000_000,
            }),
            control: Arc::new(Control::default()),
            stop_in_read: false,
        }
    }

    #[test]
    fn delayed_last_word_and_partial_frame_arrive_before_completion() {
        let mut input = fake();
        input.control.stop(input.clock);
        input.control.stop(input.clock + 500_000_000); // first release wins
        let control = input.control.clone();
        let mut output = Vec::new();
        let mut sizes = Vec::new();
        let report = run(&mut input, 0, &control, |pcm| {
            sizes.push(pcm.len());
            output.extend_from_slice(pcm);
            Ok(())
        })
        .unwrap()
        .unwrap();
        assert_eq!(output, input.samples[..4817]);
        assert_eq!(sizes.last(), Some(&17));
        assert_eq!(input.offset, 4817); // never read post-release sound
        assert_eq!(report.waited_ns, 100_000_000);
        assert!(report.timestamped);
    }

    #[test]
    fn stop_during_read_trims_before_emit_and_ready_audio_has_no_fixed_delay() {
        let mut input = fake();
        input.ready_at = 0;
        input.stop_in_read = true;
        input.stamp = Some(Timestamp {
            frame: 480,
            nanos: input.clock,
        });
        let control = input.control.clone();
        let mut output = Vec::new();
        let report = run(&mut input, 0, &control, |pcm| {
            output.extend_from_slice(pcm);
            Ok(())
        })
        .unwrap()
        .unwrap();
        assert_eq!(output, input.samples[..480]);
        assert_eq!(report.waited_ns, 0);
    }

    #[test]
    fn missing_clock_uses_start_time_and_does_not_stop_on_empty_read() {
        let mut input = fake();
        input.stamp = None;
        input.control.stop(input.clock);
        let control = input.control.clone();
        let report = run(&mut input, 900_000_000, &control, |_| Ok(()))
            .unwrap()
            .unwrap();
        assert_eq!(report.delivered, 4800);
        assert!(!report.timestamped);
        assert_eq!(report.waited_ns, 100_000_000);
    }

    #[test]
    fn release_during_full_read_still_drains_subsequent_frames() {
        let mut input = fake();
        input.ready_at = 0;
        input.stop_in_read = true;
        let control = input.control.clone();
        let mut output = Vec::new();
        let report = run(&mut input, 0, &control, |pcm| {
            output.extend_from_slice(pcm);
            Ok(())
        })
        .unwrap()
        .unwrap();
        assert_eq!(output, input.samples[..4817]);
        assert_eq!(report.waited_ns, 0);
    }

    #[test]
    fn missing_tail_times_out_and_cancel_drops_buffered_audio() {
        let mut input = fake();
        input.ready_at = u64::MAX;
        input.control.stop(input.clock);
        let control = input.control.clone();
        assert!(run(&mut input, 0, &control, |_| Ok(())).is_err());
        assert_eq!(input.clock, 1_000_000_000 + DRAIN_NS);
        control.cancel();
        assert!(
            run(&mut input, 0, &control, |_| panic!(
                "Canceled PCM must not be emitted"
            ))
            .unwrap()
            .is_none()
        );
    }
}
