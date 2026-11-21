//! On-demand CoreAudio/RemoteIO/WASAPI/ALSA input. Nothing enumerates or opens a device
//! until Session::start; the worker owns and drops the stream before completion.
use crate::{
    RATE, Result,
    capture::{self, Control, Drain, Source, Timestamp},
};
use cpal::{
    FromSample, SampleFormat, SizedSample,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use std::{
    collections::VecDeque,
    panic::AssertUnwindSafe,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

const BUFFER_FRAMES: usize = RATE * 2;

#[derive(Clone, Copy)]
struct Clock(Instant);
impl Clock {
    fn now(self) -> u64 {
        // Allow an initial device timestamp slightly before worker creation.
        self.0.elapsed().as_nanos() as u64 + 1_000_000_000
    }
}

struct Buffer {
    samples: VecDeque<i16>,
    timestamp: Option<Timestamp>,
    error: Option<String>,
}
impl Default for Buffer {
    fn default() -> Self {
        Self {
            samples: VecDeque::with_capacity(BUFFER_FRAMES),
            timestamp: None,
            error: None,
        }
    }
}
impl Buffer {
    fn push(&mut self, sample: f32) {
        if self.error.is_some() {
            return;
        }
        if !sample.is_finite() {
            self.error = Some("Microphone returned invalid audio. Recording stopped.".into());
        } else if self.samples.len() == BUFFER_FRAMES {
            self.error =
                Some("Microphone capture could not keep up. Review the transcript.".into());
        } else {
            self.samples.push_back(
                (sample.clamp(-1.0, 1.0) * 32768.0)
                    .round()
                    .clamp(-32768.0, 32767.0) as i16,
            );
        }
    }
}

/// Keep interpolation phase across callbacks; restarting it loses or repeats
/// speech at buffer boundaries on 44.1 kHz devices. Output is always mono 48 kHz.
struct Converter {
    rate: u32,
    channels: usize,
    frames: u64,
    next: u64,
    previous: f32,
}
impl Converter {
    fn new(rate: u32, channels: usize) -> Result<Self> {
        if !(8000..=192_000).contains(&rate) || !(1..=32).contains(&channels) {
            return Err("Unsupported microphone sample rate or channel count".into());
        }
        Ok(Self {
            rate,
            channels,
            frames: 0,
            next: 0,
            previous: 0.0,
        })
    }

    fn convert<T: SizedSample>(&mut self, data: &[T], buffer: &mut Buffer)
    where
        f32: FromSample<T>,
    {
        if !data.len().is_multiple_of(self.channels) {
            buffer.error = Some("Microphone returned an incomplete audio frame".into());
            return;
        }
        for channels in data.chunks_exact(self.channels) {
            let sample =
                channels.iter().map(|&s| f32::from_sample_(s)).sum::<f32>() / self.channels as f32;
            if self.frames == 0 {
                buffer.push(sample);
                self.next = self.rate as u64;
            } else {
                let end = self.frames * RATE as u64;
                while self.next <= end {
                    let fraction = (self.next - (end - RATE as u64)) as f32 / RATE as f32;
                    buffer.push(self.previous + (sample - self.previous) * fraction);
                    self.next += self.rate as u64;
                }
            }
            self.previous = sample;
            self.frames += 1;
        }
    }
}

struct Input {
    // The callback's shared buffer remains alive until CPAL disposes the stream.
    _stream: cpal::Stream,
    buffer: Arc<Mutex<Buffer>>,
    clock: Clock,
    // Declared last so it drops last: the audio session outlives the stream it hosts.
    #[cfg(target_os = "ios")]
    audio: crate::ios::Session,
}

fn build_stream<T: SizedSample>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    buffer: Arc<Mutex<Buffer>>,
    clock: Clock,
) -> Result<cpal::Stream>
where
    f32: FromSample<T>,
{
    let mut converter = Converter::new(config.sample_rate, config.channels as usize)?;
    let error_buffer = buffer.clone();
    device
        .build_input_stream(
            config,
            move |data: &[T], info: &cpal::InputCallbackInfo| {
                let now = clock.now();
                let time = info.timestamp();
                let mut buffer = buffer.lock().unwrap();
                if let Some(latency) = time.callback.checked_duration_since(time.capture) {
                    buffer.timestamp = Some(Timestamp {
                        frame: converter.frames * RATE as u64 / converter.rate as u64,
                        nanos: now.saturating_sub(latency.as_nanos() as u64),
                    });
                }
                converter.convert(data, &mut buffer);
            },
            move |error| {
                error_buffer.lock().unwrap().error =
                    Some(format!("Microphone input failed: {error}"));
            },
            Some(Duration::from_secs(5)),
        )
        .map_err(|error| {
            format!(
                "Could not open microphone: {error}. Check microphone permission and input device."
            )
        })
}

impl Input {
    /// `Ok(None)` when the recording was stopped or canceled before a device opened.
    fn open(clock: Clock, control: &Control) -> Result<Option<Self>> {
        // Permission and session ownership precede any device query, on the worker.
        #[cfg(target_os = "ios")]
        let Some(audio) = crate::ios::Session::acquire(control)? else {
            return Ok(None);
        };
        #[cfg(not(target_os = "ios"))]
        let _ = control;
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No microphone input device is available")?;
        let supported = device
            .default_input_config()
            .map_err(|error| format!("Could not configure microphone: {error}"))?;
        let config = supported.config();
        let buffer = Arc::new(Mutex::new(Buffer::default()));
        macro_rules! stream {
            ($sample:ty) => {
                build_stream::<$sample>(&device, config, buffer.clone(), clock)?
            };
        }
        let stream = match supported.sample_format() {
            SampleFormat::I8 => stream!(i8),
            SampleFormat::I16 => stream!(i16),
            SampleFormat::I24 => stream!(cpal::I24),
            SampleFormat::I32 => stream!(i32),
            SampleFormat::I64 => stream!(i64),
            SampleFormat::U8 => stream!(u8),
            SampleFormat::U16 => stream!(u16),
            SampleFormat::U24 => stream!(cpal::U24),
            SampleFormat::U32 => stream!(u32),
            SampleFormat::U64 => stream!(u64),
            SampleFormat::F32 => stream!(f32),
            SampleFormat::F64 => stream!(f64),
            format => return Err(format!("Unsupported microphone sample format: {format}")),
        };
        stream
            .play()
            .map_err(|error| format!("Could not start microphone: {error}"))?;
        Ok(Some(Self {
            _stream: stream,
            buffer,
            clock,
            #[cfg(target_os = "ios")]
            audio,
        }))
    }
}

impl Source for Input {
    fn now(&self) -> u64 {
        self.clock.now()
    }
    fn timestamp(&self) -> Option<Timestamp> {
        self.buffer.lock().unwrap().timestamp
    }
    fn read(&mut self, samples: &mut [i16]) -> Result<usize> {
        #[cfg(target_os = "ios")]
        self.audio.check_interruption()?;
        let mut buffer = self.buffer.lock().unwrap();
        if let Some(error) = &buffer.error {
            return Err(error.clone());
        }
        let count = samples.len().min(buffer.samples.len());
        for sample in &mut samples[..count] {
            *sample = buffer.samples.pop_front().unwrap();
        }
        Ok(count)
    }
    fn idle(&mut self) {
        thread::sleep(Duration::from_millis(5));
    }
}

pub struct Session {
    control: Arc<Control>,
    frames: mpsc::Receiver<Vec<i16>>,
    finished: Arc<Mutex<Option<Result<Option<Drain>>>>>,
    clock: Clock,
}

pub struct Poll {
    pub samples: Vec<i16>,
    pub done: bool,
    pub error: Option<String>,
    pub drain: Option<Drain>,
}

impl Session {
    pub fn start() -> Result<Self> {
        Self::start_with(Input::open)
    }

    fn start_with<S: Source>(
        open: impl FnOnce(Clock, &Control) -> Result<Option<S>> + Send + 'static,
    ) -> Result<Self> {
        let clock = Clock(Instant::now());
        let control = Arc::new(Control::default());
        let worker_control = control.clone();
        let (tx, frames) = mpsc::sync_channel(100); // two seconds of 20 ms packets
        let finished = Arc::new(Mutex::new(None));
        let worker_finished = finished.clone();
        thread::Builder::new()
            .name("dictation-capture".into())
            .spawn(move || {
                // A panic must still publish completion, or the UI waits forever.
                let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
                    if worker_control.is_canceled() {
                        return Ok(None);
                    }
                    // Device/permission work and all native stream ownership stay on
                    // this thread, including WASAPI COM initialization and disposal.
                    let Some(mut input) = open(clock, &worker_control)? else {
                        return Ok(None);
                    };
                    let started = clock.now();
                    capture::run(&mut input, started, &worker_control, |pcm| {
                        tx.try_send(pcm.to_vec()).map_err(|_| {
                            "Microphone capture queue is full. Review the transcript.".into()
                        })
                    })
                    // input (and the native stream) drops before publishing done.
                }))
                .unwrap_or_else(|_| Err("Microphone capture stopped unexpectedly".into()));
                *worker_finished.lock().unwrap() = Some(result);
            })
            .map_err(|_| "Could not start microphone worker")?;
        Ok(Self {
            control,
            frames,
            finished,
            clock,
        })
    }

    pub fn stop(&self) {
        self.control.stop(self.clock.now());
    }

    pub fn poll(&self) -> Poll {
        // Read completion before draining: done must never precede final PCM.
        let finished = self.finished.lock().unwrap();
        let done = finished.is_some();
        let error = finished
            .as_ref()
            .and_then(|result| result.as_ref().err())
            .cloned();
        let drain = finished
            .as_ref()
            .and_then(|result| result.as_ref().ok())
            .cloned()
            .flatten();
        drop(finished);
        Poll {
            samples: self.frames.try_iter().flatten().collect(),
            done,
            error,
            drain,
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.control.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn stereo_formats_become_mono_pcm_without_clipping_wraparound() {
        let mut converter = Converter::new(48000, 2).unwrap();
        let mut buffer = Buffer::default();
        converter.convert(&[1.0f32, 1.0, -1.0, -1.0, 0.25, 0.75], &mut buffer);
        assert_eq!(buffer.samples, [32767, -32768, 16384]);
        let mut converter = Converter::new(48000, 1).unwrap();
        buffer.samples.clear();
        converter.convert(&[0u16, 32768, 65535], &mut buffer);
        assert_eq!(buffer.samples, [-32768, 0, 32767]);
    }

    #[test]
    fn resampling_is_independent_of_callback_boundaries_and_keeps_duration() {
        for rate in [8000, 16000, 44100, 48000, 96000, 192000] {
            let data: Vec<f32> = (0..=rate).map(|i| (i as f32 * 0.031).sin() * 0.4).collect();
            let mut whole = Buffer::default();
            Converter::new(rate, 1).unwrap().convert(&data, &mut whole);
            let mut chunked = Buffer::default();
            let mut converter = Converter::new(rate, 1).unwrap();
            for chunk in data.chunks(137) {
                converter.convert(chunk, &mut chunked);
            }
            assert_eq!(whole.samples, chunked.samples);
            assert_eq!(whole.samples.len(), RATE + 1);
        }
    }

    #[test]
    fn overflow_and_invalid_audio_fail_instead_of_silently_dropping_speech() {
        let mut buffer = Buffer::default();
        for _ in 0..=BUFFER_FRAMES {
            buffer.push(0.1);
        }
        assert_eq!(buffer.samples.len(), BUFFER_FRAMES);
        assert!(buffer.error.unwrap().contains("could not keep up"));
        let mut buffer = Buffer::default();
        buffer.push(f32::NAN);
        assert!(buffer.error.is_some() && buffer.samples.is_empty());
        assert!(Converter::new(0, 1).is_err());
        assert!(Converter::new(48000, 0).is_err());
    }

    struct Fake {
        clock: Clock,
        closed: Arc<AtomicBool>,
    }
    impl Source for Fake {
        fn now(&self) -> u64 {
            self.clock.now()
        }
        fn timestamp(&self) -> Option<Timestamp> {
            Some(Timestamp {
                frame: 0,
                nanos: self.clock.now(),
            })
        }
        fn read(&mut self, _: &mut [i16]) -> Result<usize> {
            Ok(0)
        }
        fn idle(&mut self) {
            thread::sleep(Duration::from_millis(1));
        }
    }
    impl Drop for Fake {
        fn drop(&mut self) {
            self.closed.store(true, Ordering::Release);
        }
    }
    fn wait_until(mut ready: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !ready() {
            assert!(Instant::now() < deadline, "capture worker did not finish");
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn stop_closes_device_before_completion_and_cancel_closes_without_polling() {
        for cancel in [false, true] {
            let closed = Arc::new(AtomicBool::new(false));
            let worker_closed = closed.clone();
            let (tx, rx) = mpsc::channel();
            let session = Session::start_with(move |clock, _| {
                tx.send(()).unwrap();
                Ok(Some(Fake {
                    clock,
                    closed: worker_closed,
                }))
            })
            .unwrap();
            rx.recv_timeout(Duration::from_secs(2)).unwrap();
            if cancel {
                drop(session);
                wait_until(|| closed.load(Ordering::Acquire));
            } else {
                session.stop();
                wait_until(|| session.poll().done);
                assert!(closed.load(Ordering::Acquire));
                assert!(session.poll().error.is_none());
            }
        }
    }

    #[test]
    fn device_open_failure_is_delivered_without_blocking_the_ui() {
        let session = Session::start_with::<Fake>(|_, _| Err("Permission denied".into())).unwrap();
        wait_until(|| session.poll().done);
        let result = session.poll();
        assert_eq!(result.error.as_deref(), Some("Permission denied"));
        assert!(result.samples.is_empty());
    }

    #[test]
    fn released_before_open_finishes_quietly_and_a_worker_panic_still_completes() {
        let session = Session::start_with::<Fake>(|_, control| {
            // The platform adapter observed a release while waiting for permission.
            control.stop(1);
            Ok(None)
        })
        .unwrap();
        wait_until(|| session.poll().done);
        let result = session.poll();
        assert!(result.error.is_none() && result.drain.is_none() && result.samples.is_empty());

        let session = Session::start_with::<Fake>(|_, _| panic!("device layer bug")).unwrap();
        wait_until(|| session.poll().done);
        assert_eq!(
            session.poll().error.as_deref(),
            Some("Microphone capture stopped unexpectedly")
        );
    }
}
