//! Stateful hardware decoder. All compressed reference packets are decoded in
//! order off the render thread; only presentation frames may be superseded.
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_chromium_video::{Codec, DecodeError, Decoder};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    thread,
};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct ChromiumVideoDecoder {
    base: Base<RefCounted>,
    sender: Option<mpsc::SyncSender<(Vec<u8>, u64)>>,
    stop: Arc<AtomicBool>,
    /// The newest flow frame number the codec has accepted as input.
    consumed: Arc<AtomicU64>,
    /// Decoded pictures awaiting the engine, oldest first; see `PRESENTATION_QUEUE`.
    pictures: Arc<Mutex<VecDeque<PresentationFrame>>>,
    error: Arc<Mutex<String>>,
    worker: Option<thread::JoinHandle<()>>,
}

/// Pictures decoded between two engine frames are shown on consecutive frames
/// instead of replacing each other.
///
/// With decode latency jittering around the frame interval, newest-only
/// presentation left about a quarter of a tablet's frames without a new
/// picture. Two pictures bound the added latency to one.
const PRESENTATION_QUEUE: usize = 2;
// Prepare the engine's byte storage on the decoder thread. Packing several
// megabytes in take_frame otherwise stalls input, acknowledgements and drawing.
// Ownership crosses the mutex; neither thread mutates a published packed array.
struct PresentationFrame {
    width: u32,
    height: u32,
    pixels: Pixels,
}
#[cfg(any(target_os = "android", target_os = "ios"))]
type EngineBytes = PackedByteArray;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
type EngineBytes = Vec<u8>;
enum Pixels {
    Rgba(EngineBytes),
    /// Luma and interleaved chroma planes for conversion on the GPU.
    Nv12(EngineBytes, EngineBytes),
}
fn engine_bytes(bytes: &[u8]) -> EngineBytes {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return PackedByteArray::from(bytes);
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    return bytes.to_vec();
}
fn packed(bytes: &EngineBytes) -> PackedByteArray {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return bytes.clone();
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    return PackedByteArray::from(bytes.as_slice());
}
struct PanicReport(Arc<Mutex<String>>);
impl Drop for PanicReport {
    fn drop(&mut self) {
        if thread::panicking() {
            *self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = "Hardware video decoder worker crashed".into();
        }
    }
}
/// Decode (or, without a packet, poll) one frame in the requested layout.
fn present(decoder: &mut Decoder, packet: Option<&[u8]>, nv12: bool) -> Result<Option<PresentationFrame>, DecodeError> {
    if nv12 {
        let frame = match packet {
            Some(bytes) => decoder.decode_nv12(bytes)?,
            None => decoder.poll_nv12()?,
        };
        return Ok(frame.map(|frame| PresentationFrame {
            width: frame.width,
            height: frame.height,
            pixels: Pixels::Nv12(engine_bytes(frame.y), engine_bytes(frame.uv)),
        }));
    }
    let frame = match packet {
        Some(bytes) => decoder.decode(bytes)?,
        None => decoder.poll()?,
    };
    Ok(frame.map(|frame| PresentationFrame {
        width: frame.width,
        height: frame.height,
        pixels: Pixels::Rgba(engine_bytes(&frame.rgba)),
    }))
}

// SAFETY: PackedByteArray contains refcounted bytes, no engine objects. This
// private wrapper transfers exclusive ownership through the mailbox mutex;
// conversion finishes before publication and consumers only read/clone it.
//
// Mobile builds enable gdext's thread-safe FFI tables for
// construction/destruction.
#[cfg(any(target_os = "android", target_os = "ios"))]
unsafe impl Send for PresentationFrame {}
#[godot_api]
impl IRefCounted for ChromiumVideoDecoder {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            sender: None,
            stop: Arc::new(AtomicBool::new(false)),
            consumed: Arc::new(AtomicU64::new(0)),
            pictures: Arc::new(Mutex::new(VecDeque::with_capacity(PRESENTATION_QUEUE))),
            error: Arc::new(Mutex::new(String::new())),
            worker: None,
        }
    }
}
#[godot_api]
impl ChromiumVideoDecoder {
    #[func]
    fn supported_codecs(&self) -> PackedStringArray {
        graffitty_chromium_video::decoders()
            .iter()
            .map(|c| GString::from(c.name()))
            .collect()
    }
    /// With `nv12`, frames carry "y" and "uv" planes for conversion on the
    /// GPU instead of CPU-converted "rgba".
    #[func]
    fn start(&mut self, codec: GString, width: i64, height: i64, implementation: GString, nv12: bool) -> bool {
        if self.sender.is_some() {
            return false;
        }
        let Some(codec) = Codec::parse(&codec.to_string()) else {
            return false;
        };
        let Ok(mut decoder) = Decoder::named(
            codec,
            &implementation.to_string(),
            width as u32,
            height as u32,
        ) else {
            return false;
        };
        let (tx, rx) = mpsc::sync_channel::<(Vec<u8>, u64)>(32);
        self.sender = Some(tx);
        let (pictures, error, consumed) = (self.pictures.clone(), self.error.clone(), self.consumed.clone());
        let stop = self.stop.clone();
        // Named so a device trace attributes decoding and plane copies.
        let spawned = thread::Builder::new().name("ChromiumVideo".into()).spawn(move || {
            // A panicking worker must report failure: without an error the
            // session would only recreate the decoder, never reject the codec.
            let _exit = PanicReport(error.clone());
            let mut pending = None;
            // The codec returns one picture per call; another decoded beside
            // it is collected at once rather than after waiting for input.
            let mut draining = false;
            while !stop.load(Ordering::Relaxed) {
                if pending.is_none() {
                    let next = if draining {
                        rx.try_recv().map_err(|error| matches!(error, mpsc::TryRecvError::Disconnected))
                    } else {
                        // VideoToolbox completes synchronously on this worker;
                        // there is no delayed output to poll while the page is idle.
                        #[cfg(target_os = "ios")]
                        { rx.recv().map_err(|_| true) }
                        #[cfg(not(target_os = "ios"))]
                        { rx.recv_timeout(std::time::Duration::from_millis(4))
                            .map_err(|error| matches!(error, mpsc::RecvTimeoutError::Disconnected)) }
                    };
                    match next {
                        Ok(bytes) => pending = Some(bytes),
                        Err(true) => break,
                        Err(false) => {}
                    }
                }
                let result = present(&mut decoder, pending.as_ref().map(|(bytes, _)| bytes.as_slice()), nv12);
                let result = if matches!(result, Err(DecodeError::Backpressure)) {
                    // Keep the access unit ahead of the bounded input queue.
                    // Polling returns output buffers to the codec and presents
                    // frames even while its input pool is temporarily full.
                    let result = present(&mut decoder, None, nv12);
                    if !matches!(result, Ok(Some(_))) {
                        thread::sleep(std::time::Duration::from_millis(4));
                    }
                    result
                } else {
                    if let Some((_, frame)) = pending.take() {
                        consumed.fetch_max(frame, Ordering::Relaxed);
                    }
                    result
                };
                match result {
                    Ok(Some(frame)) => {
                        let superseded = {
                            let mut queue = pictures.lock().unwrap();
                            let oldest = (queue.len() == PRESENTATION_QUEUE).then(|| queue.pop_front()).flatten();
                            queue.push_back(frame);
                            oldest
                        };
                        drop(superseded);
                        draining = true;
                    }
                    Ok(None) => draining = false,
                    Err(message) => {
                        *error.lock().unwrap() = message.to_string();
                        break;
                    }
                }
            }
        });
        let Ok(worker) = spawned else {
            self.sender = None;
            return false;
        };
        self.worker = Some(worker);
        true
    }
    /// `frame` is the packet's flow number; `consumed` reports it once the
    /// codec accepts the packet, so acknowledgements track decoding.
    #[func]
    fn submit(&self, packet: PackedByteArray, frame: i64) -> bool {
        self.sender
            .as_ref()
            .is_some_and(|tx| tx.try_send((packet.to_vec(), frame.max(0) as u64)).is_ok())
    }
    #[func]
    fn consumed(&self) -> i64 {
        self.consumed.load(Ordering::Relaxed) as i64
    }
    #[func]
    fn take_frame(&self) -> VarDictionary {
        let mut result = VarDictionary::new();
        let frame = self.pictures.lock().unwrap().pop_front();
        if let Some(frame) = frame {
            result.set("width", frame.width);
            result.set("height", frame.height);
            match &frame.pixels {
                Pixels::Rgba(rgba) => result.set("rgba", &packed(rgba)),
                Pixels::Nv12(y, uv) => {
                    result.set("y", &packed(y));
                    result.set("uv", &packed(uv));
                }
            }
        }
        let error = self.error.lock().unwrap();
        if !error.is_empty() {
            result.set("error", error.as_str());
        }
        result
    }
}
impl Drop for ChromiumVideoDecoder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
