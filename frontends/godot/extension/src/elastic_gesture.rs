//! Reads the scroll phases of Godot pan gestures for the shared rubber band
//! (`scroll::ElasticGesture`).
//!
//! macOS reports phases on the event; touch scrolls carry the phases the touch
//! recognizer gave them; Wayland's come from a listener beside Godot's.
use godot::classes::InputEventPanGesture;
use godot::prelude::*;

use crate::scroll::{ElasticGesture, ScrollGesture};

/// Godot's macOS backend scales native scroll pixels by 0.03 into pan
/// gesture deltas; Wayland forwards pixels unscaled.
pub(crate) const PAN_TO_PIXELS: f64 = if cfg!(target_os = "macos") {
    1.0 / 0.03
} else {
    1.0
};

/// Monotonic seconds, for rubber band timing.
pub(crate) fn clock() -> f64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

/// Per-scroller phase state that Godot's events do not carry.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct PanPhases {
    /// The Wayland finger scroll this scroller last saw.
    #[cfg(target_os = "linux")]
    wayland_scroll: Option<u64>,
}

impl PanPhases {
    /// The scroll phases a pan gesture carries, where the platform reports them.
    pub fn read(&mut self, pan: &Gd<InputEventPanGesture>, band: &ElasticGesture) -> Option<ScrollGesture> {
        let phase = |name: &str| pan.has_meta(name).then(|| pan.get_meta(name).to_string());
        let (finger, momentum) = (phase("scroll_phase"), phase("momentum_phase"));
        #[cfg(target_os = "linux")]
        {
            if finger.is_none() && momentum.is_none() {
                return crate::touchpad_wayland::finger_scroll().map(|serial| {
                    let began = self.wayland_scroll != Some(serial) || !band.elastic.scrolling();
                    self.wayland_scroll = Some(serial);
                    ScrollGesture { began, ..Default::default() }
                });
            }
        }
        #[cfg(not(target_os = "linux"))]
        let _ = band;
        let stage = momentum.as_deref().or(finger.as_deref())?;
        Some(ScrollGesture {
            began: stage == "began",
            ended: matches!(stage, "ended" | "cancelled"),
            momentum: momentum.is_some(),
            time: pan.has_meta("event_time").then(|| pan.get_meta("event_time").to::<f64>()),
            // AppKit reports momentum just after the fingers lift; Chromium
            // waits this long for it before treating the lift as the end.
            hold_end: cfg!(target_os = "macos") && momentum.is_none() && !pan.has_meta("touch_travel"),
        })
    }

    /// Whether a Wayland finger scroll this scroller follows has stopped,
    /// which ends its gesture.
    pub fn stopped(&mut self, band: &ElasticGesture) -> bool {
        #[cfg(target_os = "linux")]
        {
            if band.elastic.scrolling() && self.wayland_scroll.is_some_and(crate::touchpad_wayland::stopped) {
                self.wayland_scroll = None;
                return true;
            }
        }
        let _ = band;
        false
    }
}
