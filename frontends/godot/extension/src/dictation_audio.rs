#[cfg(target_os = "android")]
use audio::android as native_capture;
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux", target_os = "ios"))]
use audio::device as native_capture;
use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use graffitty_dictation_audio as audio;

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct DictationAudio {
    base: Base<RefCounted>,
    live_encoder: Option<audio::live::LiveEncoder>,
    #[cfg(any(
        target_os = "android",
        target_os = "macos",
        target_os = "windows",
        target_os = "linux",
        target_os = "ios"
    ))]
    capture: Option<native_capture::Session>,
}
#[godot_api]
impl IRefCounted for DictationAudio {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            live_encoder: None,
            #[cfg(any(
                target_os = "android",
                target_os = "macos",
                target_os = "windows",
                target_os = "linux",
                target_os = "ios"
            ))]
            capture: None,
        }
    }
}
fn bytes(result: audio::Result<Vec<u8>>) -> VarDictionary {
    let mut reply = VarDictionary::new();
    match result {
        Ok(data) => {
            reply.set("audio", &PackedByteArray::from(data.as_slice()));
        }
        Err(error) => {
            reply.set("error", error);
        }
    }
    reply
}
#[godot_api]
impl DictationAudio {
    #[func]
    fn has_native_capture() -> bool {
        #[cfg(target_os = "android")]
        {
            audio::android::available()
        }
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux", target_os = "ios"))]
        {
            // Capability only: never enumerate or open devices during UI setup.
            true
        }
        #[cfg(not(any(
            target_os = "android",
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "ios"
        )))]
        {
            false
        }
    }

    #[func]
    fn encode_opus(frames: PackedVector2Array, rate: i64) -> VarDictionary {
        if !(8000..=48000).contains(&rate) || frames.len() > rate as usize * 10 {
            return bytes(Err(
                "Unsupported microphone sample rate or segment length".into()
            ));
        }
        let mono: Vec<f32> = frames
            .as_slice()
            .iter()
            .map(|s| (s.x + s.y) * 0.5)
            .collect();
        bytes(audio::encode(&mono, rate as u32))
    }

    /// One stateful encoder per recording; PCM is local only, never the wire format.
    #[func]
    fn encode_live(&mut self, pcm: PackedByteArray, finish: bool) -> VarDictionary {
        let result = (|| {
            if pcm.len() % 2 != 0 || pcm.len() > audio::live::MAX_INPUT_SAMPLES * 2 {
                return Err("Invalid live microphone PCM chunk".into());
            }
            if self.live_encoder.is_none() {
                self.live_encoder = Some(audio::live::LiveEncoder::new()?);
            }
            let samples: Vec<f32> = pcm.as_slice().chunks_exact(2)
                .map(|s| i16::from_le_bytes([s[0], s[1]]) as f32 / 32768.0)
                .collect();
            self.live_encoder.as_mut().unwrap().encode(&samples, finish)
        })();
        bytes(result)
    }

    /// Direct-device requests use the same validation and format policy as the server.
    #[func]
    fn provider_audio(
        opus: PackedByteArray,
        provider: GString,
        model: GString,
        base_url: GString,
    ) -> VarDictionary {
        match audio::provider_audio(
            opus.as_slice(),
            &provider.to_string(),
            &model.to_string(),
            &base_url.to_string(),
        ) {
            Ok(audio) => {
                let mut reply = bytes(Ok(audio.bytes));
                reply.set("format", audio.format);
                reply.set("mime", audio.mime);
                reply
            }
            Err(error) => bytes(Err(error)),
        }
    }

    /// Decode to WAV for compatibility and capture-duration diagnostics.
    #[func]
    fn provider_wave(opus: PackedByteArray) -> VarDictionary {
        bytes(audio::provider_wave(opus.as_slice()))
    }

    #[func]
    fn start_capture(&mut self) -> GString {
        #[cfg(any(
            target_os = "android",
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "ios"
        ))]
        {
            if self.capture.is_some() {
                return "Microphone is already active".into();
            }
            match native_capture::Session::start() {
                Ok(capture) => {
                    self.capture = Some(capture);
                    GString::new()
                }
                Err(error) => GString::from(&error),
            }
        }
        #[cfg(not(any(
            target_os = "android",
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "ios"
        )))]
        {
            "Native microphone capture is unavailable on this platform".into()
        }
    }

    #[func]
    fn stop_capture(&self) {
        #[cfg(any(
            target_os = "android",
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "ios"
        ))]
        if let Some(capture) = &self.capture {
            capture.stop();
        }
    }

    #[func]
    fn cancel_capture(&mut self) {
        #[cfg(any(
            target_os = "android",
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "ios"
        ))]
        {
            self.capture = None;
        }
    }

    #[func]
    fn poll_capture(&mut self) -> VarDictionary {
        let mut result = VarDictionary::new();
        #[cfg(any(
            target_os = "android",
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "ios"
        ))]
        if let Some(capture) = &self.capture {
            let poll = capture.poll();
            let frames: Vec<Vector2> = poll
                .samples
                .iter()
                .map(|&s| {
                    let sample = s as f32 / 32768.0;
                    Vector2::new(sample, sample)
                })
                .collect();
            result.set("frames", &PackedVector2Array::from(frames.as_slice()));
            result.set("done", poll.done);
            if let Some(drain) = poll.drain {
                result.set("target_frames", drain.target as i64);
                result.set("delivered_frames", drain.delivered as i64);
                result.set("timestamped", drain.timestamped);
                result.set("drain_ms", drain.waited_ns as f64 / 1_000_000.0);
            }
            if let Some(error) = poll.error {
                result.set("error", error);
            }
            if poll.done {
                self.capture = None;
            }
            return result;
        }
        result.set("frames", &PackedVector2Array::new());
        result.set("done", true);
        result
    }
}
