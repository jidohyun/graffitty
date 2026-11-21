//! Short, on-demand output. No device/stream remains open between alerts.
use godot::{classes::{IRefCounted, RefCounted}, prelude::*};
use std::sync::mpsc::{self, Receiver, Sender};

mod output;

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AttentionAudio {
    base: Base<RefCounted>,
    tx: Sender<Result<(), String>>,
    rx: Receiver<Result<(), String>>,
    active: usize,
    completed: usize,
}
#[godot_api]
impl IRefCounted for AttentionAudio {
    fn init(base: Base<RefCounted>) -> Self {
        let (tx, rx) = mpsc::channel();
        Self { base, tx, rx, active: 0, completed: 0 }
    }
}
#[godot_api]
impl AttentionAudio {
    #[func]
    fn play(&mut self, frames: PackedVector2Array, rate: i64) -> GString {
        if !(8000..=192000).contains(&rate) || frames.is_empty() || frames.len() > rate as usize * 10 {
            return "Invalid attention audio (maximum 10 seconds)".into();
        }
        if self.active >= 4 { return "Too many concurrent attention sounds".into(); }
        let pcm: Vec<[f32; 2]> = frames.as_slice().iter().map(|v| [v.x, v.y]).collect();
        if pcm.iter().flatten().any(|v| !v.is_finite()) { return "Invalid audio samples".into(); }
        let tx = self.tx.clone();
        match std::thread::Builder::new().name("attention-audio".into()).spawn(move || {
            let _ = tx.send(output::play(pcm, rate as u32));
        }) {
            Ok(_) => { self.active += 1; GString::new() }
            Err(e) => e.to_string().as_str().into(),
        }
    }
    #[func]
    fn poll(&mut self) -> VarDictionary {
        let mut error = String::new();
        while let Ok(result) = self.rx.try_recv() {
            self.active = self.active.saturating_sub(1);
            match result { Ok(()) => self.completed += 1, Err(e) => error = e }
        }
        let mut result = VarDictionary::new();
        result.set("active", self.active as i64);
        result.set("completed", self.completed as i64);
        result.set("error", error);
        result
    }
}
