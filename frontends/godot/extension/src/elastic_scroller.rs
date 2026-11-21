//! A pixel scroller that moves like a terminal: phased trackpad and touch
//! pans, finger drags with momentum, and the rubber band past either end.
//!
//! The scroll surface keeps its own offset and passes it in with its range;
//! the scroller returns the new offset and reports the pull to draw.
use godot::classes::InputEventPanGesture;
use godot::prelude::*;
use graffitty_scene_core::glam::Vec2;
use graffitty_scene_core::fling::ScrollMotion;

use crate::elastic_gesture::{PAN_TO_PIXELS, PanPhases, clock};
use crate::scroll::{ElasticConfig, ElasticGesture, ScrollGesture, Scroller};

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct ElasticScroller {
    base: Base<RefCounted>,
    band: ElasticGesture,
    phases: PanPhases,
    /// A finger fling after release.
    momentum: ScrollMotion,
    /// A finger is down, or its fling is still moving the content.
    touching: bool,
    flinging: bool,
    /// Scroll sideways instead of down.
    #[var]
    horizontal: bool,
    /// Seconds to use as now, for tests; negative follows the monotonic clock.
    #[var]
    fixed_time: f64,
}

#[godot_api]
impl IRefCounted for ElasticScroller {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            band: ElasticGesture::new(ElasticConfig::terminal()),
            phases: PanPhases::default(),
            momentum: ScrollMotion::default(),
            touching: false,
            flinging: false,
            horizontal: false,
            fixed_time: -1.0,
        }
    }
}

fn msec(now: f64) -> i64 {
    (now * 1000.0) as i64
}

impl ElasticScroller {
    fn now(&self) -> f64 {
        if self.fixed_time >= 0.0 { self.fixed_time } else { clock() }
    }

    fn along(&self, v: Vector2) -> f64 {
        f64::from(if self.horizontal { v.x } else { v.y })
    }

    fn touch_phase(&self, began: bool, ended: bool, momentum: bool, now: f64) -> ScrollGesture {
        ScrollGesture { began, ended, momentum, time: Some(now), hold_end: false }
    }
}

#[godot_api]
impl ElasticScroller {
    /// Scroll by a pan gesture from `offset` in `0..=max`, `page` pixels
    /// visible. `along` is the event's delta along this scroller (a strip may
    /// fold both axes into one). Returns the new offset. Phased pans
    /// (trackpads, and touch scrolls the recognizer turned into pans) pull
    /// past either end.
    #[func]
    fn pan(&mut self, event: Gd<InputEventPanGesture>, along: f64, offset: f64, max: f64, page: f64) -> f64 {
        let now = self.now();
        if self.touching || self.flinging {
            self.momentum.stop();
            self.touching = false;
            self.flinging = false;
        }
        let gesture = self.phases.read(&event, &self.band);
        let delta = along * PAN_TO_PIXELS;
        self.band.scroll(offset, max, page, delta, gesture, now)
    }

    /// Scroll by a wheel or other unphased step; never stretches.
    #[func]
    fn step(&mut self, delta: f64, offset: f64, max: f64, page: f64) -> f64 {
        self.band.scroll(offset, max, page, delta, None, self.now())
    }

    /// A finger landed: stop any glide and begin a drag.
    #[func]
    fn touch_begin(&mut self) {
        let now = self.now();
        self.momentum.begin(msec(now));
        self.touching = true;
        self.flinging = false;
        self.band.began(self.touch_phase(true, false, false, now), true);
    }

    /// The finger moved by `relative` screen pixels; the content follows it.
    #[func]
    fn touch_move(&mut self, relative: Vector2, offset: f64, max: f64, page: f64) -> f64 {
        if !self.touching {
            return offset;
        }
        let now = self.now();
        self.momentum.track(Vec2::new(relative.x, relative.y), msec(now));
        let gesture = self.touch_phase(false, false, false, now);
        self.band.scroll(offset, max, page, -self.along(relative), Some(gesture), now)
    }

    /// The finger lifted: with `fling`, a flick glides on; otherwise the
    /// pull releases where it is (a mouse drag never flings).
    #[func]
    fn touch_end(&mut self, offset: f64, max: f64, page: f64, fling: bool) {
        if !self.touching {
            return;
        }
        let now = self.now();
        self.touching = false;
        if fling {
            self.momentum.release(msec(now));
        } else {
            self.momentum.stop();
        }
        if self.momentum.velocity() == Vec2::ZERO {
            self.band.ended(self.touch_phase(false, true, false, now), now, Scroller { offset, max, bounds: page });
        } else {
            self.flinging = true;
        }
    }

    /// Advance a glide and a release. Returns the new offset; call each
    /// frame while `is_active()`.
    #[func]
    fn advance(&mut self, offset: f64, max: f64, page: f64) -> f64 {
        let now = self.now();
        let mut offset = offset;
        if self.flinging {
            let travel = self.momentum.advance(msec(now));
            let gesture = self.touch_phase(false, false, true, now);
            let moved = Vector2::new(travel.x, travel.y);
            let before = offset;
            offset = self.band.scroll(offset, max, page, -self.along(moved), Some(gesture), now);
            // A fling that bounced off an end and sprang back has nothing
            // left to move; it ends there rather than coasting on unseen.
            let pinned = self.along(moved) != 0.0 && offset == before && self.band.elastic.stretch() == 0.0;
            if pinned {
                self.momentum.stop();
            }
            if pinned || self.momentum.velocity() == Vec2::ZERO {
                self.flinging = false;
                self.band.ended(self.touch_phase(false, true, true, now), now, Scroller { offset, max, bounds: page });
            }
        }
        let scroller = Scroller { offset, max, bounds: page };
        if self.phases.stopped(&self.band) {
            self.band.end(now, scroller);
        }
        self.band.tick(now, scroller, true);
        offset
    }

    /// The pull in pixels: negative past the start, positive past the end.
    #[func]
    fn get_stretch(&self) -> f64 {
        self.band.elastic.stretch()
    }

    /// Whether a drag, glide, pull or release needs `advance` each frame.
    #[func]
    fn is_active(&self) -> bool {
        self.touching || self.flinging || self.band.active()
    }

    /// Whether a lifted finger's flick is still gliding the content.
    #[func]
    fn is_flinging(&self) -> bool {
        self.flinging
    }

    /// Whether a finger is dragging the content now.
    #[func]
    fn is_touching(&self) -> bool {
        self.touching
    }

    /// A scrollbar thumb `(start, length)` along `track`, shortened against
    /// the pulled end while `stretch` is non-zero (`scroll::scroll_thumb`).
    #[func]
    fn thumb(&self, track: f64, offset: f64, max: f64, page: f64, stretch: f64, min_length: f64) -> Vector2 {
        let (start, length) = crate::scroll::scroll_thumb(track, offset, max, page, stretch, min_length);
        Vector2::new(start as f32, length as f32)
    }

    /// Drop any drag, glide and pull, as when the content is replaced.
    #[func]
    fn stop(&mut self) {
        self.momentum.stop();
        self.touching = false;
        self.flinging = false;
        self.band.elastic.reset();
    }
}
