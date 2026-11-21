//! AAudio input uses the device capture clock instead of Godot's mixer buffer.
//! The stream stays alive until all samples through stop have been read.
use crate::{
    RATE, Result,
    capture::{self, Control, Drain, Source, Timestamp},
};
use std::{
    ffi::c_void,
    ptr,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::Duration,
};

// Load on demand: input presets exist from Android 9, and Android 8 records
// with its default preset. Android 8 is the client's minimum.
macro_rules! aaudio_api {
    ($(fn $name:ident($($arg:ident: $ty:ty),* $(,)?) $(-> $out:ty)?;)+
     $(optional fn $optional:ident($($optional_arg:ident: $optional_ty:ty),* $(,)?);)*) => {
        #[allow(non_snake_case)]
        struct Api {
            $($name: unsafe extern "C" fn($($ty),*) $(-> $out)?,)+
            $($optional: Option<unsafe extern "C" fn($($optional_ty),*)>,)*
            _library: libloading::Library,
        }
        impl Api {
            fn load() -> Result<Arc<Self>> {
                let library = unsafe { libloading::Library::new("libaaudio.so") }
                    .map_err(|_| "Native microphone capture is unavailable")?;
                Ok(Arc::new(Self {
                    $($name: *unsafe { library.get::<unsafe extern "C" fn($($ty),*) $(-> $out)?>(
                        concat!(stringify!($name), "\0").as_bytes()) }
                        .map_err(|_| "Native microphone capture is unavailable")?,)+
                    $($optional: unsafe { library.get::<unsafe extern "C" fn($($optional_ty),*)>(
                        concat!(stringify!($optional), "\0").as_bytes()) }.ok().map(|symbol| *symbol),)*
                    _library: library,
                }))
            }
        }
    }
}
aaudio_api! {
    fn AAudio_createStreamBuilder(builder: *mut *mut c_void) -> i32;
    fn AAudioStreamBuilder_delete(builder: *mut c_void) -> i32;
    fn AAudioStreamBuilder_setDirection(builder: *mut c_void, direction: i32);
    fn AAudioStreamBuilder_setFormat(builder: *mut c_void, format: i32);
    fn AAudioStreamBuilder_setChannelCount(builder: *mut c_void, count: i32);
    fn AAudioStreamBuilder_setSampleRate(builder: *mut c_void, rate: i32);
    fn AAudioStreamBuilder_setBufferCapacityInFrames(builder: *mut c_void, frames: i32);
    fn AAudioStreamBuilder_openStream(builder: *mut c_void, stream: *mut *mut c_void) -> i32;
    fn AAudioStream_getSampleRate(stream: *mut c_void) -> i32;
    fn AAudioStream_getChannelCount(stream: *mut c_void) -> i32;
    fn AAudioStream_getFormat(stream: *mut c_void) -> i32;
    fn AAudioStream_getXRunCount(stream: *mut c_void) -> i32;
    fn AAudioStream_requestStart(stream: *mut c_void) -> i32;
    fn AAudioStream_requestStop(stream: *mut c_void) -> i32;
    fn AAudioStream_close(stream: *mut c_void) -> i32;
    fn AAudioStream_read(
        stream: *mut c_void,
        buffer: *mut c_void,
        frames: i32,
        timeout: i64,
    ) -> i32;
    fn AAudioStream_getTimestamp(
        stream: *mut c_void,
        clock: i32,
        frame: *mut i64,
        nanos: *mut i64
    ) -> i32;
    optional fn AAudioStreamBuilder_setInputPreset(builder: *mut c_void, preset: i32);
}

pub fn now() -> u64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // CLOCK_MONOTONIC is also the clock passed to AAudioStream_getTimestamp.
    unsafe {
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time);
    }
    time.tv_sec as u64 * 1_000_000_000 + time.tv_nsec as u64
}

pub fn available() -> bool {
    Api::load().is_ok()
}

struct Input {
    stream: *mut c_void,
    api: Arc<Api>,
}
// Ownership moves once to the capture worker; no stream methods run concurrently.
unsafe impl Send for Input {}
impl Drop for Input {
    fn drop(&mut self) {
        unsafe {
            (self.api.AAudioStream_requestStop)(self.stream);
            (self.api.AAudioStream_close)(self.stream);
        }
    }
}
impl Input {
    fn open() -> Result<Self> {
        let api = Api::load()?;
        unsafe {
            let mut builder = ptr::null_mut();
            if (api.AAudio_createStreamBuilder)(&mut builder) != 0 {
                return Err("Could not create microphone input".into());
            }
            (api.AAudioStreamBuilder_setDirection)(builder, 1); // INPUT
            (api.AAudioStreamBuilder_setFormat)(builder, 1); // PCM_I16
            (api.AAudioStreamBuilder_setChannelCount)(builder, 1);
            (api.AAudioStreamBuilder_setSampleRate)(builder, RATE as i32);
            if let Some(set_input_preset) = api.AAudioStreamBuilder_setInputPreset {
                set_input_preset(builder, 6); // VOICE_RECOGNITION
            }
            (api.AAudioStreamBuilder_setBufferCapacityInFrames)(builder, 9600);
            let mut stream = ptr::null_mut();
            let result = (api.AAudioStreamBuilder_openStream)(builder, &mut stream);
            (api.AAudioStreamBuilder_delete)(builder);
            if result != 0 || stream.is_null() {
                return Err(format!(
                    "Could not open microphone ({result}). Check microphone permission."
                ));
            }
            let input = Self {
                stream,
                api: api.clone(),
            };
            if (api.AAudioStream_getSampleRate)(stream) != RATE as i32
                || (api.AAudioStream_getChannelCount)(stream) != 1
                || (api.AAudioStream_getFormat)(stream) != 1
            {
                return Err("Microphone could not provide mono 48 kHz PCM16".into());
            }
            Ok(input)
        }
    }
}
impl Source for Input {
    fn now(&self) -> u64 {
        now()
    }
    fn read(&mut self, samples: &mut [i16]) -> Result<usize> {
        unsafe {
            if (self.api.AAudioStream_getXRunCount)(self.stream) > 0 {
                return Err("Microphone capture could not keep up. Review the transcript.".into());
            }
            let count = (self.api.AAudioStream_read)(
                self.stream,
                samples.as_mut_ptr().cast(),
                samples.len() as i32,
                0,
            );
            if count < 0 {
                Err(format!("Microphone input failed ({count})"))
            } else {
                Ok(count as usize)
            }
        }
    }
    fn timestamp(&self) -> Option<Timestamp> {
        let (mut frame, mut nanos) = (0, 0);
        let ok = unsafe {
            (self.api.AAudioStream_getTimestamp)(
                self.stream,
                libc::CLOCK_MONOTONIC,
                &mut frame,
                &mut nanos,
            )
        };
        (ok == 0 && frame >= 0 && nanos > 0).then_some(Timestamp {
            frame: frame as u64,
            nanos: nanos as u64,
        })
    }
    fn idle(&mut self) {
        thread::sleep(Duration::from_millis(5));
    }
}

pub struct Session {
    control: Arc<Control>,
    frames: mpsc::Receiver<Vec<i16>>,
    finished: Arc<Mutex<Option<Result<Option<Drain>>>>>,
}
pub struct Poll {
    pub samples: Vec<i16>,
    pub done: bool,
    pub error: Option<String>,
    pub drain: Option<Drain>,
}
impl Session {
    pub fn start() -> Result<Self> {
        let mut input = Input::open()?;
        let started = now();
        let result = unsafe { (input.api.AAudioStream_requestStart)(input.stream) };
        if result != 0 {
            return Err(format!("Could not start microphone ({result})"));
        }
        let control = Arc::new(Control::default());
        let worker_control = control.clone();
        let (tx, frames) = mpsc::sync_channel(100); // at most two seconds of PCM
        let finished = Arc::new(Mutex::new(None));
        let worker_finished = finished.clone();
        thread::Builder::new()
            .name("dictation-capture".into())
            .spawn(move || {
                let result = capture::run(&mut input, started, &worker_control, |pcm| {
                    tx.try_send(pcm.to_vec()).map_err(|_| {
                        "Microphone capture queue is full. Review the transcript.".into()
                    })
                });
                drop(input); // close the microphone before making completion visible
                *worker_finished.lock().unwrap() = Some(result);
            })
            .map_err(|_| "Could not start microphone worker")?;
        Ok(Self {
            control,
            frames,
            finished,
        })
    }
    pub fn stop(&self) {
        self.control.stop(now());
    }
    pub fn poll(&self) -> Poll {
        // Observe completion first, then drain the queue, so done cannot precede final PCM.
        let finished = self.finished.lock().unwrap();
        let done = finished.is_some();
        let error = finished
            .as_ref()
            .and_then(|result| result.as_ref().err())
            .cloned();
        let drain = finished
            .as_ref()
            .and_then(|result| result.as_ref().ok())
            .and_then(|drain| drain.clone());
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
