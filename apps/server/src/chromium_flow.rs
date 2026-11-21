//! Wait for client acknowledgements before sending more Chromium frames,
//! as with terminal scene chunks.
//!
//! The limit keeps stale video from building up ahead of terminal updates.
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

/// Grow the in-flight window with the measured round trip. A fixed window of
/// four frames capped a 130 ms link at about 26 fps despite spare bandwidth.
///
/// Keep at least four frames in flight even during congestion. A tablet that
/// acks once per 30 ms engine frame can vary by two engine frames with an
/// empty queue. A two-frame window held it near 25 fps.
///
/// The byte budget still limits slow links.
const MIN_FRAMES: usize = 4;
const MAX_FRAMES: usize = 16;
/// Unacknowledged bytes per frame slot. One frame may always be in flight,
/// so a keyframe or full-page image larger than the budget still goes out.
const BYTES_PER_FRAME: usize = 32 * 1024;
const MIN_BYTES: usize = 128 * 1024;
const FRAME_INTERVAL: Duration = Duration::from_micros(16_667);
/// Queueing delay that shows spare link capacity, or a link that is filling.
const IDLE_QUEUE: Duration = Duration::from_millis(25);
const BUSY_QUEUE: Duration = Duration::from_millis(60);
/// A client that reads its socket once per rendered frame delays most
/// acknowledgements by up to that frame, but some are always prompt, while a
/// filling link delays every one.
///
/// The shortest delay over the last round trip (at least this long) separates
/// the two.
const STANDING_WINDOW: Duration = Duration::from_millis(100);
/// The longest hold a client may report for one frame; see `acknowledge_held`.
const MAX_HELD: Duration = Duration::from_secs(1);
/// The minimum round trip is re-learned so a changed route can raise it.
const ROUND_TRIP_MEMORY: Duration = Duration::from_secs(10);
/// A window this old belongs to a stalled connection, not a slow one.
const STALLED: Duration = Duration::from_secs(2);
/// No acknowledgement for this long: the frame is lost for good, not merely
/// a large keyframe still crossing a narrow link. The stream restarts.
const STUCK: Duration = Duration::from_secs(5);
/// Shares of a pane's bitrate budget a viewer's link may select. Each change
/// starts a new rendition at a keyframe, so the steps are coarse.
const BITRATE_TIERS: [f32; 7] = [1.0, 0.7, 0.5, 0.35, 0.25, 0.18, 0.12];
/// Queueing that lowers the bitrate. A client acknowledging once per rendered
/// frame adds one or two of its frames; a filling link adds far more.
const BITRATE_QUEUE: Duration = Duration::from_millis(150);
/// One burst of losses lowers the bitrate once, not once per lost packet.
/// Each change reopens a hardware encoder and costs a keyframe.
const BITRATE_LOWER_HOLD: Duration = Duration::from_secs(1);
/// A link that stayed clear this long tries the next higher bitrate.
const BITRATE_RAISE_HOLD: Duration = Duration::from_secs(4);

pub struct Flow {
    last: u64,
    /// Frame number, bytes, send time, and whether it entered an empty window.
    unacknowledged: VecDeque<(u64, usize, Instant, bool)>,
    frames: usize,
    shortest: Option<(Duration, Instant)>,
    round_trip: Option<Duration>,
    /// Recent acknowledgement delays and when they arrived.
    recent: VecDeque<(Instant, Duration)>,
    adjusted: Option<Instant>,
    traced: Option<Instant>,
    /// Index into BITRATE_TIERS, and when it last changed or was confirmed
    /// against congestion. Both describe the link, so restarts keep them.
    tier: usize,
    tier_changed: Option<Instant>,
}

impl Default for Flow {
    fn default() -> Self {
        Self {
            last: 0,
            unacknowledged: VecDeque::new(),
            frames: MIN_FRAMES,
            shortest: None,
            round_trip: None,
            recent: VecDeque::new(),
            adjusted: None,
            traced: None,
            tier: 0,
            tier_changed: None,
        }
    }
}

impl Flow {
    /// A pane subscribed again starts a fresh window and round-trip history,
    /// but its numbering continues: the client acknowledges the newest frame
    /// its decoder accepted, which numbers restarting at 1 would never exceed.
    pub fn restart(&mut self) {
        *self = Self { last: self.last, tier: self.tier, tier_changed: self.tier_changed, ..Self::default() };
    }

    /// The oldest frame went unacknowledged so long that it never will be.
    /// Restart at a keyframe, at a bitrate the link can carry.
    pub fn recover_stall(&mut self) {
        self.lower_bitrate(2, Instant::now());
        self.restart();
    }

    /// The share of the pane's bitrate budget this viewer's link carries.
    pub fn bitrate_share(&self) -> f32 {
        BITRATE_TIERS[self.tier]
    }

    fn lower_bitrate(&mut self, steps: usize, now: Instant) {
        if self.tier_changed.is_some_and(|at| now - at < BITRATE_LOWER_HOLD) { return; }
        let tier = (self.tier + steps).min(BITRATE_TIERS.len() - 1);
        self.tier_changed = Some(now);
        if tier != self.tier {
            self.tier = tier;
            trace_bitrate(self.tier);
        }
    }

    fn raise_bitrate(&mut self, now: Instant) {
        if self.tier == 0 || self.tier_changed.is_some_and(|at| now - at < BITRATE_RAISE_HOLD) { return; }
        self.tier -= 1;
        self.tier_changed = Some(now);
        trace_bitrate(self.tier);
    }

    pub fn ready(&self) -> bool {
        self.unacknowledged.is_empty()
            || (self.unacknowledged.len() < self.frames
                && self.unacknowledged.iter().map(|(_, size, _, _)| size).sum::<usize>()
                    < (self.frames * BYTES_PER_FRAME).max(MIN_BYTES))
    }

    /// Pause video while the link is delivering but the in-flight window is full.
    /// When there is room, encode the newest frame and skip older ones.
    /// Sending ahead can force repeated keyframe restarts.
    pub fn saturated(&self) -> bool {
        !self.ready() && !self.stalled()
    }

    /// Split a shared rendition only after appreciable queueing. Ordinary
    /// frame-scheduled acknowledgements briefly fill even a healthy window.
    pub fn congested(&self) -> bool {
        !self.ready() && self.unacknowledged.front().is_some_and(|(_, _, sent, _)| sent.elapsed() >= Duration::from_millis(100))
    }

    /// The oldest frame has waited so long that the connection, not the
    /// link rate, is the problem; see `saturated`.
    pub fn stuck(&self) -> bool {
        self.unacknowledged.front().is_some_and(|(_, _, sent, _)| sent.elapsed() >= STUCK)
    }

    pub fn stalled(&self) -> bool {
        self.unacknowledged.front().is_some_and(|(_, _, sent, _)| sent.elapsed() >= STALLED)
    }

    /// Numbers the next frame; its header carries the number back in the
    /// client's acknowledgement.
    pub fn send(&mut self, size: usize) -> u64 {
        self.send_at(size, Instant::now())
    }

    fn send_at(&mut self, size: usize, now: Instant) -> u64 {
        self.last += 1;
        let alone = self.unacknowledged.is_empty();
        self.unacknowledged.push_back((self.last, size, now, alone));
        self.last
    }

    /// Acknowledgements are cumulative because the client handles frames in order.
    pub fn acknowledge(&mut self, frame: u64) {
        self.acknowledge_held(frame, Duration::ZERO);
    }

    /// `held`: how long the client kept the frame before acknowledging it. A
    /// client acknowledges from its render loop once its decoder accepted the
    /// frame, one or two rendered frames after arrival.
    ///
    /// That wait is not link delay; counted as such it reads as a filling
    /// link and pins the window at its minimum.
    pub fn acknowledge_held(&mut self, frame: u64, held: Duration) {
        self.acknowledge_at(frame, Instant::now(), held);
    }

    fn acknowledge_at(&mut self, frame: u64, now: Instant, held: Duration) {
        let mut sample = None;
        while let Some(&(number, size, sent, alone)) = self.unacknowledged.front() {
            if number > frame {
                break;
            }
            self.unacknowledged.pop_front();
            // A large keyframe's transmission time is not round-trip delay.
            sample = (size <= BYTES_PER_FRAME)
                .then(|| (now.saturating_duration_since(sent).saturating_sub(held.min(MAX_HELD)), alone));
        }
        if let Some((sample, alone)) = sample {
            self.adapt(sample, alone, now);
        }
    }

    /// A datagram receiver reported a lost frame fragment. Loss is the
    /// strongest congestion signal: shrink as for a filling queue, at most
    /// once per round trip, since one burst usually loses several packets.
    pub fn lost(&mut self) {
        self.lost_at(Instant::now());
    }

    fn lost_at(&mut self, now: Instant) {
        self.lower_bitrate(1, now);
        let round_trip = self.round_trip.unwrap_or(FRAME_INTERVAL);
        if self.adjusted.is_none_or(|at| now - at >= round_trip.max(FRAME_INTERVAL)) {
            self.frames = (self.frames * 3 / 4).max(MIN_FRAMES);
            self.adjusted = Some(now);
        }
    }

    /// Unacknowledged bytes this window allows, the datagram pacer's budget
    /// per round trip.
    pub fn window_bytes(&self) -> usize {
        (self.frames * BYTES_PER_FRAME).max(MIN_BYTES)
    }

    /// The shortest recently observed acknowledgement delay.
    pub fn round_trip(&self) -> Option<Duration> {
        self.shortest.map(|(shortest, _)| shortest)
    }

    /// Adapt the in-flight window at most once per round trip.
    ///
    /// - With no queueing, add one frame toward enough room for 60 fps.
    /// - When queueing begins, shrink the window. This keeps latency low on a
    ///   slow link by limiting how many stale frames can build up.
    fn adapt(&mut self, sample: Duration, alone: bool, now: Instant) {
        // Update the minimum round trip from any sample at or below the baseline.
        // After ROUND_TRIP_MEMORY, allow a longer baseline from a frame that
        // entered an empty window. Queued samples include time spent waiting.
        if self.shortest.is_none_or(|(shortest, at)| sample <= shortest || (alone && now - at > ROUND_TRIP_MEMORY)) {
            self.shortest = Some((sample, now));
        }
        let round_trip = self.round_trip.map_or(sample, |previous| (previous * 7 + sample) / 8);
        self.round_trip = Some(round_trip);
        self.recent.push_back((now, sample));
        while self.recent.front().is_some_and(|(at, _)| now - *at > round_trip.max(STANDING_WINDOW)) {
            self.recent.pop_front();
        }
        let shortest = self.shortest.map_or(sample, |(shortest, _)| shortest);
        let standing = self.recent.iter().map(|(_, delay)| *delay).min().unwrap_or(sample);
        static TRACE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        if *TRACE.get_or_init(|| std::env::var("RUST_LOG").unwrap_or_default().contains("graffitty_video"))
            && self.traced.is_none_or(|at| now - at >= Duration::from_secs(1))
        {
            eprintln!("chromium flow window={} outstanding={} rtt_ms={} standing_ms={} minimum_ms={}",
                self.frames, self.unacknowledged.len(), round_trip.as_millis(), standing.as_millis(),
                shortest.as_millis());
            self.traced = Some(now);
        }
        let queue = standing.saturating_sub(shortest);
        // Bitrate follows the link independently of the window's own pace:
        // smaller frames, not fewer, when the link is filling.
        if queue > BITRATE_QUEUE {
            self.lower_bitrate(1, now);
        } else {
            self.raise_bitrate(now);
        }
        if self.adjusted.is_some_and(|at| now - at < round_trip.max(FRAME_INTERVAL)) {
            return;
        }
        // Enough frames to cover the acknowledgement delay actually observed,
        // including the client's frame scheduling, keep 60 fps flowing.
        let target = ((round_trip.as_secs_f64() / FRAME_INTERVAL.as_secs_f64()).ceil() as usize + 2)
            .clamp(MIN_FRAMES, MAX_FRAMES);
        if queue > BUSY_QUEUE {
            self.frames = (self.frames * 3 / 4).max(MIN_FRAMES);
            self.adjusted = Some(now);
        } else if queue < IDLE_QUEUE && self.frames < target {
            self.frames += 1;
            self.adjusted = Some(now);
        }
    }
}

fn trace_bitrate(tier: usize) {
    static TRACE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if *TRACE.get_or_init(|| std::env::var("RUST_LOG").unwrap_or_default().contains("graffitty_video")) {
        eprintln!("chromium flow bitrate share={}", BITRATE_TIERS[tier]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn budget_bounds_bytes_and_frames_but_never_blocks_one_frame() {
        let mut flow = Flow::default();
        assert_eq!(flow.send(MIN_BYTES * 4), 1);
        assert!(!flow.ready(), "An oversized keyframe waits for its acknowledgement");
        flow.acknowledge(1);
        assert!(flow.ready());
        for _ in 0..MIN_FRAMES {
            assert!(flow.ready());
            flow.send(1024);
        }
        assert!(!flow.ready(), "Small frames are capped by count");
    }

    #[test]
    fn loss_shrinks_the_window_once_per_round_trip() {
        let mut flow = Flow { frames: MAX_FRAMES, ..Flow::default() };
        flow.lost();
        assert_eq!(flow.frames, MAX_FRAMES * 3 / 4);
        flow.lost();
        assert_eq!(flow.frames, MAX_FRAMES * 3 / 4, "One burst of losses shrinks the window once");
        assert_eq!(flow.window_bytes(), MAX_FRAMES * 3 / 4 * BYTES_PER_FRAME);
        let mut small = Flow::default();
        small.lost();
        assert_eq!(small.frames, MIN_FRAMES, "Loss never shrinks below the minimum window");
    }

    #[test]
    fn resubscribed_panes_continue_numbering_with_a_fresh_window() {
        let mut flow = Flow::default();
        for _ in 0..MIN_FRAMES {
            flow.send(1024);
        }
        assert!(!flow.ready());
        flow.restart();
        assert!(flow.ready(), "Frames sent before unsubscribing no longer hold the window");
        let next = flow.send(1024);
        assert_eq!(next, MIN_FRAMES as u64 + 1, "A resumed decoder's newest frame still advances the window");
        flow.acknowledge(2);
        assert_eq!(flow.unacknowledged.len(), 1, "A late acknowledgement from before the restart frees nothing new");
        flow.acknowledge(next);
        assert!(flow.unacknowledged.is_empty());
    }

    #[test]
    fn loss_lowers_bitrate_once_per_burst_and_a_clear_link_raises_it() {
        let mut flow = Flow::default();
        let now = Instant::now();
        assert_eq!(flow.bitrate_share(), 1.0);
        flow.lost_at(now);
        flow.lost_at(now + Duration::from_millis(100));
        assert_eq!(flow.bitrate_share(), BITRATE_TIERS[1], "One burst of losses lowers one tier");
        flow.lost_at(now + BITRATE_LOWER_HOLD);
        assert_eq!(flow.bitrate_share(), BITRATE_TIERS[2], "Continued loss keeps lowering");
        let clear = now + BITRATE_LOWER_HOLD + Duration::from_millis(100);
        for _ in 0..3 { flow.adapt(Duration::from_millis(20), true, clear); }
        assert_eq!(flow.bitrate_share(), BITRATE_TIERS[2], "A clear link waits before raising");
        flow.adapt(Duration::from_millis(20), true, now + BITRATE_LOWER_HOLD + BITRATE_RAISE_HOLD);
        assert_eq!(flow.bitrate_share(), BITRATE_TIERS[1]);
        flow.restart();
        assert_eq!(flow.bitrate_share(), BITRATE_TIERS[1], "Restarting the stream keeps the link's bitrate");
    }

    #[test]
    fn queueing_lowers_bitrate_but_client_frame_pacing_does_not() {
        let mut flow = Flow::default();
        let now = Instant::now();
        flow.adapt(Duration::from_millis(20), true, now);
        // A client acknowledging once per 44 ms frame: up to two frames late.
        for step in 1..20 {
            flow.adapt(Duration::from_millis(20 + (step % 3) * 44), false, now + Duration::from_millis(step * 30));
        }
        assert_eq!(flow.bitrate_share(), 1.0, "Frame-paced acknowledgements are not congestion");
        let later = now + Duration::from_secs(1);
        for step in 0..10 {
            flow.adapt(Duration::from_millis(400), false, later + Duration::from_millis(step * 20));
        }
        assert!(flow.bitrate_share() < 1.0, "A filling link lowers the bitrate");
    }

    #[test]
    fn a_clients_reported_hold_is_not_link_delay() {
        // A phone acknowledging from its 40 ms render loop over a 50 ms route:
        // after one prompt reply, every acknowledgement is 40 to 80 ms late.
        let run = |reported: bool| {
            let mut flow = Flow::default();
            let start = Instant::now();
            for step in 0..200u64 {
                let sent = start + Duration::from_millis(step * 40);
                let number = flow.send_at(1024, sent);
                let held = Duration::from_millis(if step > 0 { 40 + (step % 2) * 40 } else { 0 });
                flow.acknowledge_at(number, sent + Duration::from_millis(50) + held,
                    if reported { held } else { Duration::ZERO });
            }
            flow.frames
        };
        assert_eq!(run(false), MIN_FRAMES, "Unreported holds look like a queue on the link");
        assert!(run(true) > MIN_FRAMES, "Reported holds leave the window free to grow");
    }

    #[test]
    fn a_stalled_stream_restarts_at_a_lower_bitrate() {
        let mut flow = Flow::default();
        flow.send(512 * 1024);
        assert!(!flow.ready(), "One keyframe over the byte budget fills the window");
        flow.recover_stall();
        assert!(flow.ready(), "A lost frame can no longer hold the stream");
        assert_eq!(flow.bitrate_share(), BITRATE_TIERS[2]);
    }

    #[test]
    fn a_full_window_pauses_video_until_acknowledged_or_stalled() {
        let mut flow = Flow::default();
        assert!(!flow.saturated());
        for _ in 0..MIN_FRAMES {
            flow.send(1024);
        }
        assert!(flow.saturated(), "A live link with a full window cannot take a fresher frame");
        flow.acknowledge(1);
        assert!(!flow.saturated());
        flow.send(1024);
        flow.unacknowledged.front_mut().unwrap().2 -= STALLED;
        assert!(!flow.ready() && !flow.saturated() && flow.stalled(), "A stalled connection cannot pause shared video");
    }

    #[test]
    fn only_sustained_full_windows_need_independent_pacing() {
        let mut flow = Flow::default();
        let now = Instant::now();
        for _ in 0..MIN_FRAMES { flow.send_at(1024, now); }
        assert!(!flow.congested());
        flow.unacknowledged.front_mut().unwrap().2 -= Duration::from_millis(110);
        assert!(flow.congested());
        flow.acknowledge(1);
        assert!(!flow.congested(), "A ready viewer does not split the rendition");
    }

    #[test]
    fn acknowledgements_are_cumulative_and_late_ones_are_harmless() {
        let mut flow = Flow::default();
        let first = flow.send(100 * 1024);
        let second = flow.send(100 * 1024);
        assert!(!flow.ready());
        flow.acknowledge(second);
        assert!(flow.ready());
        flow.acknowledge(first);
        assert_eq!(flow.send(10), 3, "Numbers never repeat on one connection");
        flow.acknowledge(2);
        assert!(!flow.unacknowledged.is_empty(), "A late acknowledgement keeps newer frames in flight");
    }

    #[test]
    fn long_idle_round_trips_grow_the_window_and_queueing_shrinks_it() {
        let mut flow = Flow::default();
        let start = Instant::now();
        let mut now = start;
        for _ in 0..20 {
            now += Duration::from_millis(130);
            flow.adapt(Duration::from_millis(130), false, now);
        }
        assert_eq!(flow.frames, 10, "One round trip of 60 fps frames plus two");
        for _ in 0..20 {
            now += Duration::from_millis(300);
            flow.adapt(Duration::from_millis(300), false, now);
        }
        assert!(flow.frames < 6, "A queueing link sheds in-flight frames: {}", flow.frames);
        // Lasting congestion must not become the new baseline after it expires.
        for _ in 0..60 {
            now += Duration::from_millis(300);
            flow.adapt(Duration::from_millis(300), false, now);
        }
        assert_eq!(flow.frames, MIN_FRAMES, "Queued samples never reset the shortest round trip");
        now += Duration::from_millis(300);
        flow.adapt(Duration::from_millis(300), true, now);
        assert_eq!(flow.shortest.unwrap().0, Duration::from_millis(300), "An unqueued frame re-learns a longer route");
        let mut local = Flow::default();
        for step in 1..=50 {
            local.adapt(Duration::from_millis(2), false, start + FRAME_INTERVAL * step);
        }
        assert_eq!(local.frames, MIN_FRAMES, "A local link keeps the low-latency window");
    }

    /// Deterministic link model. The page offers a frame every 16.7 ms and
    /// one goes out whenever the window has room.
    ///
    /// A frame reaches the client after `one_way` plus `delay`, in order; the
    /// client reads its socket only at `polls` (the frames it renders) and
    /// each acknowledgement then takes `one_way` back.
    ///
    /// Returns frames sent per second after `measure_from`.
    fn simulate(flow: &mut Flow, until: Duration, measure_from: Duration, one_way: Duration,
        delay: impl Fn(Duration, u64) -> Duration, polls: &std::collections::HashSet<u128>) -> f64 {
        let start = Instant::now();
        let (mut in_flight, mut returning) = (VecDeque::new(), VecDeque::new());
        let (mut next_frame, mut arrival, mut sent, mut t) = (Duration::ZERO, Duration::ZERO, 0, Duration::ZERO);
        while t < until {
            while returning.front().is_some_and(|&(_, at)| at <= t) {
                let (frame, _) = returning.pop_front().unwrap();
                flow.acknowledge_at(frame, start + t, Duration::ZERO);
            }
            if t >= next_frame && flow.ready() {
                let frame = flow.send_at(1024, start + t);
                arrival = arrival.max(t + one_way + delay(t, frame));
                in_flight.push_back((frame, arrival));
                next_frame = t + FRAME_INTERVAL;
                sent += usize::from(t >= measure_from);
            }
            if polls.contains(&t.as_millis()) {
                while in_flight.front().is_some_and(|&(_, at)| at <= t) {
                    returning.push_back((in_flight.pop_front().unwrap().0, t + one_way));
                }
            }
            t += Duration::from_millis(1);
        }
        sent as f64 / (until - measure_from).as_secs_f64()
    }

    /// Client render times: a steady period with a longer hitch every tenth frame.
    fn renders(from_ms: u128, until_ms: u128, period: u128, hitch: u128) -> std::collections::HashSet<u128> {
        let (mut at, mut count, mut result) = (from_ms, 0, std::collections::HashSet::new());
        while at < until_ms {
            result.insert(at);
            count += 1;
            at += if count % 10 == 0 { hitch } else { period };
        }
        result
    }

    #[test]
    fn frame_scheduled_mobile_acknowledgements_keep_60_fps_after_a_startup_stall() {
        // A tablet rendering at 28 fps with 90 ms hitches over jittery Wi-Fi;
        // nothing is read during the first 1.5 s of codec startup.
        let mut flow = Flow::default();
        let wifi = |_: Duration, frame: u64| Duration::from_millis(frame.wrapping_mul(2_654_435_761) % 41);
        let fps = simulate(&mut flow, Duration::from_secs(10), Duration::from_secs(4), Duration::from_millis(12),
            wifi, &renders(1500, 10_000, 36, 90));
        assert!(fps >= 50.0, "Client scheduling delay is not congestion: {fps:.1} fps, window {}", flow.frames);
        assert!(flow.frames < MAX_FRAMES, "The window covers the observed delay, not the maximum");
    }

    #[test]
    fn a_standing_queue_contracts_the_window_despite_prompt_history() {
        let mut flow = Flow::default();
        let queue = |t: Duration, _| if t >= Duration::from_secs(3) { Duration::from_millis(250) } else { Duration::ZERO };
        simulate(&mut flow, Duration::from_secs(8), Duration::from_secs(7), Duration::from_millis(12),
            queue, &renders(0, 8_000, 16, 16));
        assert_eq!(flow.frames, MIN_FRAMES, "Every acknowledgement delayed by a filling link means congestion");
        let mut local = Flow::default();
        let fps = simulate(&mut local, Duration::from_secs(4), Duration::from_secs(1), Duration::from_millis(1),
            |_, _| Duration::ZERO, &renders(0, 4_000, 16, 16));
        assert!(fps >= 55.0 && local.frames == MIN_FRAMES, "A local link keeps 60 fps with the low-latency window");
    }
}
