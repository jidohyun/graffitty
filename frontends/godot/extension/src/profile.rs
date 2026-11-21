//! Process-step CPU accounting for native nodes, read by `graffitty/frame_profile.gd`.
use godot::{classes::RefCounted, prelude::*};
use std::sync::Mutex;
use std::time::Instant;

static TOTALS: Mutex<Vec<(&'static str, u64, u64)>> = Mutex::new(Vec::new());

/// Measures one callback; dropping it records the elapsed time under `label`.
pub struct Span {
    label: &'static str,
    started: Instant,
}
impl Span {
    pub fn new(label: &'static str) -> Self {
        Self { label, started: Instant::now() }
    }
}
impl Drop for Span {
    fn drop(&mut self) {
        let elapsed = self.started.elapsed().as_micros() as u64;
        let Ok(mut totals) = TOTALS.lock() else { return };
        if let Some(entry) = totals.iter_mut().find(|(label, _, _)| *label == self.label) {
            entry.1 += elapsed;
            entry.2 += 1;
        } else {
            totals.push((self.label, elapsed, 1));
        }
    }
}

#[derive(GodotClass)]
#[class(init, base = RefCounted)]
struct NativeFrameProfile {
    base: Base<RefCounted>,
}
#[godot_api]
impl NativeFrameProfile {
    /// `{label: PackedInt64Array[usec, calls]}` since the previous call.
    #[func]
    fn take(&self) -> VarDictionary {
        let mut result = VarDictionary::new();
        if let Ok(mut totals) = TOTALS.lock() {
            for (label, usec, calls) in totals.drain(..) {
                result.set(label, &PackedInt64Array::from(&[usec as i64, calls as i64][..]));
            }
        }
        result
    }
}
