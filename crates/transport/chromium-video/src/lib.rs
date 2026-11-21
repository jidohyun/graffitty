//! Hardware-only low-delay codecs shared by the session server and Godot client.
//! No software encoder/decoder is advertised as hardware support.
use serde::{Deserialize, Serialize};
use std::sync::{Mutex, Once, OnceLock, atomic::{AtomicU8, Ordering}};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[repr(i32)]
pub enum Codec {
    H264,
    Hevc,
    Av1,
}
impl Codec {
    pub const PREFERENCE: [Self; 3] = [Self::Av1, Self::Hevc, Self::H264];
    pub fn name(self) -> &'static str {
        match self {
            Self::Av1 => "av1",
            Self::Hevc => "hevc",
            Self::H264 => "h264",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        Self::PREFERENCE.into_iter().find(|c| c.name() == value)
    }
}
pub fn negotiate(server: &[Codec], client: &[Codec]) -> Option<Codec> {
    Codec::PREFERENCE
        .into_iter()
        .find(|c| server.contains(c) && client.contains(c))
}
pub struct Encoded {
    pub bytes: Vec<u8>,
    pub key: bool,
}
pub struct Decoded {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
}
/// A decoded frame for color conversion on the GPU: full-resolution luma
/// rows, then interleaved Cb/Cr rows at half resolution. It borrows the
/// decoder's frame buffer until the next decode.
pub struct Nv12<'a> {
    pub width: u32,
    pub height: u32,
    pub y: &'a [u8],
    pub uv: &'a [u8],
}
const RGBA: i32 = 0;
const NV12: i32 = 1;

#[cfg(any(target_os = "ios", all(test, target_os = "macos")))]
mod apple;

#[cfg(chromium_video)]
mod native {
    use std::ffi::c_void;
    unsafe extern "C" {
        pub fn gv_encoder(codec: i32, width: i32, height: i32, bitrate: i32, fps: i32) -> *mut c_void;
        pub fn gv_decoder(codec: i32) -> *mut c_void;
        pub fn gv_decoder_named(
            codec: i32,
            name: *const std::ffi::c_char,
            width: i32,
            height: i32,
        ) -> *mut c_void;
        pub fn gv_free(video: *mut c_void);
        pub fn gv_set_bitrate(video: *mut c_void, bitrate: i32);
        pub fn gv_encode(
            video: *mut c_void,
            rgba: *const u8,
            key: i32,
            bytes: *mut *const u8,
            is_key: *mut i32,
        ) -> i32;
        pub fn gv_decode(
            video: *mut c_void,
            bytes: *const u8,
            length: i32,
            format: i32,
            frame: *mut *const u8,
            width: *mut i32,
            height: *mut i32,
        ) -> i32;
    }
    pub struct Handle(pub *mut c_void);
    // A codec is exclusively owned and used by one worker; never shared concurrently.
    unsafe impl Send for Handle {}
    impl Drop for Handle {
        fn drop(&mut self) {
            unsafe { gv_free(self.0) };
        }
    }
}
pub struct Encoder {
    #[cfg(chromium_video)]
    handle: native::Handle,
    width: u32,
    height: u32,
}
impl Encoder {
    pub fn new(codec: Codec, width: u32, height: u32) -> Result<Self, String> {
        Self::configured(codec, width, height, 0, 60)
    }
    pub fn configured(codec: Codec, width: u32, height: u32, bitrate: u32, fps: u32) -> Result<Self, String> {
        if bitrate > 200_000_000 || !(1..=120).contains(&fps) { return Err("Invalid video encoding settings".into()); }
        #[cfg(chromium_video)]
        {
            let ptr = unsafe { native::gv_encoder(codec as i32, width as i32, height as i32, bitrate as i32, fps as i32) };
            if !ptr.is_null() {
                return Ok(Self {
                    handle: native::Handle(ptr),
                    width,
                    height,
                });
            }
        }
        let _ = (codec, width, height);
        Err("Hardware video encoder unavailable for this codec/size".into())
    }
    /// Bits per second for the next frames, without a keyframe where the
    /// platform encoder supports live rate changes.
    pub fn set_bitrate(&mut self, bitrate: u32) {
        #[cfg(chromium_video)]
        unsafe { native::gv_set_bitrate(self.handle.0, bitrate.min(200_000_000) as i32) };
        #[cfg(not(chromium_video))]
        let _ = bitrate;
    }
    pub fn encode(&mut self, rgba: &[u8], key: bool) -> Result<Option<Encoded>, String> {
        if rgba.len() != self.width as usize * self.height as usize * 4 {
            return Err("Invalid video frame size".into());
        }
        #[cfg(chromium_video)]
        {
            let (mut bytes, mut is_key) = (std::ptr::null(), 0);
            let length = unsafe {
                native::gv_encode(
                    self.handle.0,
                    rgba.as_ptr(),
                    key.into(),
                    &mut bytes,
                    &mut is_key,
                )
            };
            if length > 0 {
                return Ok(Some(Encoded {
                    bytes: unsafe { std::slice::from_raw_parts(bytes, length as usize) }.to_vec(),
                    key: is_key != 0,
                }));
            }
            if length == 0 {
                return Ok(None);
            }
        }
        let _ = key;
        Err("Hardware video encoding failed".into())
    }
}
/// Input backpressure is transient: retry the same access unit after polling
/// output. A failure invalidates the decoder and requires codec renegotiation.
#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    Backpressure,
    Failure(&'static str),
}
impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Backpressure => f.write_str("Hardware decoder input is busy"),
            Self::Failure(message) => f.write_str(message),
        }
    }
}
impl std::error::Error for DecodeError {}
impl From<&'static str> for DecodeError {
    fn from(message: &'static str) -> Self { Self::Failure(message) }
}
pub struct Decoder {
    #[cfg(chromium_video)]
    handle: native::Handle,
    #[cfg(target_os = "ios")]
    apple: apple::Decoder,
}
impl Decoder {
    pub fn new(codec: Codec) -> Result<Self, String> {
        #[cfg(target_os = "ios")]
        return apple::Decoder::new(codec, "", 0, 0).map(|apple| Self { apple });
        #[cfg(chromium_video)]
        {
            let ptr = unsafe { native::gv_decoder(codec as i32) };
            if !ptr.is_null() {
                return Ok(Self {
                    handle: native::Handle(ptr),
                });
            }
        }
        #[cfg(not(target_os = "ios"))]
        { let _ = codec; Err("Hardware video decoder unavailable".into()) }
    }
    pub fn named(codec: Codec, name: &str, width: u32, height: u32) -> Result<Self, String> {
        #[cfg(target_os = "ios")]
        return apple::Decoder::new(codec, name, width, height).map(|apple| Self { apple });
        #[cfg(chromium_video)]
        {
            let name = std::ffi::CString::new(name).map_err(|_| "Invalid decoder name")?;
            let ptr = unsafe {
                native::gv_decoder_named(codec as i32, name.as_ptr(), width as i32, height as i32)
            };
            if !ptr.is_null() {
                return Ok(Self {
                    handle: native::Handle(ptr),
                });
            }
        }
        #[cfg(not(target_os = "ios"))]
        { let _ = (codec, name, width, height); Err("Hardware video decoder initialization failed".into()) }
    }
    pub fn poll(&mut self) -> Result<Option<Decoded>, DecodeError> {
        Ok(self.frame(&[], RGBA)?.map(|(rgba, width, height)| Decoded { rgba: rgba.to_vec(), width, height }))
    }
    pub fn decode(&mut self, bytes: &[u8]) -> Result<Option<Decoded>, DecodeError> {
        if bytes.is_empty() {
            return Err("Empty video packet".into());
        }
        Ok(self.frame(bytes, RGBA)?.map(|(rgba, width, height)| Decoded { rgba: rgba.to_vec(), width, height }))
    }
    pub fn poll_nv12(&mut self) -> Result<Option<Nv12<'_>>, DecodeError> {
        Ok(self.frame(&[], NV12)?.map(nv12))
    }
    pub fn decode_nv12(&mut self, bytes: &[u8]) -> Result<Option<Nv12<'_>>, DecodeError> {
        if bytes.is_empty() {
            return Err("Empty video packet".into());
        }
        Ok(self.frame(bytes, NV12)?.map(nv12))
    }
    #[cfg(target_os = "ios")]
    fn frame(&mut self, bytes: &[u8], format: i32) -> Result<Option<(&[u8], u32, u32)>, DecodeError> {
        self.apple.frame(bytes, format)
    }
    #[cfg(not(target_os = "ios"))]
    fn frame(&mut self, bytes: &[u8], format: i32) -> Result<Option<(&[u8], u32, u32)>, DecodeError> {
        if bytes.len() > 8 * 1024 * 1024 {
            return Err("Invalid video packet size".into());
        }
        #[cfg(chromium_video)]
        {
            let (mut frame, mut width, mut height) = (std::ptr::null(), 0, 0);
            let length = unsafe {
                native::gv_decode(
                    self.handle.0,
                    bytes.as_ptr(),
                    bytes.len() as i32,
                    format,
                    &mut frame,
                    &mut width,
                    &mut height,
                )
            };
            if length > 0 {
                // The codec owns this buffer until its next decode, which
                // requires &mut self while the returned borrow is alive.
                let frame = unsafe { std::slice::from_raw_parts(frame, length as usize) };
                return Ok(Some((frame, width as u32, height as u32)));
            }
            if length == 0 {
                return Ok(None);
            }
            if length == -2 {
                return Err(DecodeError::Backpressure);
            }
        }
        let _ = format;
        Err("Hardware video decoding failed".into())
    }
}
fn nv12((frame, width, height): (&[u8], u32, u32)) -> Nv12<'_> {
    let (y, uv) = frame.split_at(width as usize * height as usize);
    Nv12 { width, height, y, uv }
}
// Stable slices let callers read an accumulating set without locks or leaked
// allocations. Bit positions match Codec's native representation.
const ENCODER_SETS: [&[Codec]; 8] = [
    &[], &[Codec::H264], &[Codec::Hevc], &[Codec::Hevc, Codec::H264],
    &[Codec::Av1], &[Codec::Av1, Codec::H264], &[Codec::Av1, Codec::Hevc],
    &[Codec::Av1, Codec::Hevc, Codec::H264],
];
struct EncoderCapabilities {
    initial: Once,
    known: AtomicU8,
    retry: Mutex<Option<Instant>>,
}
impl EncoderCapabilities {
    const fn new() -> Self {
        Self {initial: Once::new(), known: AtomicU8::new(0), retry: Mutex::new(None)}
    }
    fn codecs(&self) -> &'static [Codec] {
        ENCODER_SETS[self.known.load(Ordering::Acquire) as usize]
    }
    fn refresh(&self, probe: fn(&[Codec]) -> Vec<Codec>, delay: Duration) {
        let missing: Vec<_> = Codec::PREFERENCE.into_iter().filter(|c| !self.codecs().contains(c)).collect();
        let mask = probe(&missing).into_iter().fold(0, |mask, codec| mask | (1 << codec as u8));
        // Cache proven hardware support. Negative probes may just mean that
        // another process currently owns every available encoder session.
        self.known.fetch_or(mask, Ordering::Release);
        *self.retry.lock().unwrap() = Some(Instant::now() + delay);
    }
    fn get(&'static self, probe: fn(&[Codec]) -> Vec<Codec>, requested: &[Codec], delay: Duration) -> &'static [Codec] {
        let mut initial = false;
        self.initial.call_once(|| { self.refresh(probe, delay); initial = true; });
        if self.codecs().iter().any(|c| requested.contains(c)) { return self.codecs(); }
        if !initial && !requested.is_empty() {
            let mut retry = self.retry.lock().unwrap();
            if retry.is_some_and(|at| Instant::now() >= at) {
                *retry = None; // At most one probe can be in flight.
                // Startup probes synchronously. Retry missing codecs off the
                // input/network thread, only when no known codec serves this
                // client. A working fallback does not cause periodic probing.
                if std::thread::Builder::new().name("video-capability-probe".into())
                    .spawn(move || self.refresh(probe, delay)).is_err()
                {
                    *retry = Some(Instant::now() + delay);
                }
            }
        }
        self.codecs()
    }
}
#[cfg(any(windows, all(chromium_video, target_os = "linux")))]
use surface::probe_encoders;
#[cfg(not(any(windows, all(chromium_video, target_os = "linux"))))]
fn probe_encoders(requested: &[Codec]) -> Vec<Codec> {
    requested.iter().copied().filter(|&codec| {
        // Hardware encoders have minimum dimensions (NVENC rejects 64x64).
        // Submit real pixels rather than advertising compiled-in codec names.
        let Ok(mut encoder) = Encoder::new(codec, 256, 256) else { return false; };
        let pixels = vec![96; 256 * 256 * 4];
        (0..8).any(|_| matches!(encoder.encode(&pixels, true), Ok(Some(_))))
    }).collect()
}
/// Proven hardware codecs. If none serves `requested`, retry missing hardware
/// capabilities in the background after temporary allocation failures.
pub fn encoders(requested: &[Codec]) -> &'static [Codec] {
    static CAPS: EncoderCapabilities = EncoderCapabilities::new();
    CAPS.get(probe_encoders, requested, Duration::from_secs(5))
}
pub fn decoders() -> &'static [Codec] {
    static CAPS: OnceLock<Vec<Codec>> = OnceLock::new();
    CAPS.get_or_init(|| {
        Codec::PREFERENCE
            .into_iter()
            .filter(|&codec| Decoder::new(codec).is_ok())
            .collect()
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn encoder_capability_cache_recovers_after_exhaustion() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CACHE: super::EncoderCapabilities = super::EncoderCapabilities::new();
        static ATTEMPTS: AtomicUsize = AtomicUsize::new(0);
        fn probe(_: &[super::Codec]) -> Vec<super::Codec> {
            match ATTEMPTS.fetch_add(1, Ordering::SeqCst) {
                0 => vec![],
                1 => vec![super::Codec::H264],
                _ => vec![super::Codec::Hevc],
            }
        }
        let delay = std::time::Duration::from_millis(20);
        assert!(CACHE.get(probe, &[super::Codec::H264], delay).is_empty());
        let start = std::time::Instant::now();
        while CACHE.get(probe, &[super::Codec::H264], delay).is_empty() {
            assert!(start.elapsed() < std::time::Duration::from_secs(2));
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        for _ in 0..100 { assert_eq!(CACHE.get(probe, &[super::Codec::H264], delay), &[super::Codec::H264]); }
        assert_eq!(ATTEMPTS.load(Ordering::SeqCst), 2, "Successful capabilities must remain cached");
        // A partial result from startup must not permanently exclude a codec
        // whose allocation failed before another hardware slot became free.
        while !CACHE.get(probe, &[super::Codec::Hevc], delay).contains(&super::Codec::Hevc) {
            assert!(start.elapsed() < std::time::Duration::from_secs(2));
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(CACHE.get(probe, &super::Codec::PREFERENCE, delay), &[super::Codec::Hevc, super::Codec::H264]);
        assert_eq!(ATTEMPTS.load(Ordering::SeqCst), 3);
    }

    use super::*;
    /// The live rate change must shrink frames on the open session: reopening
    /// an encoder costs a keyframe that a narrow link cannot carry.
    #[cfg(all(chromium_video, target_os = "macos"))]
    #[test]
    fn a_live_bitrate_change_shrinks_frames_without_a_keyframe() {
        let Some(&codec) = encoders(&[Codec::Hevc, Codec::H264]).first() else { return; };
        let (width, height) = (640, 360);
        let mut encoder = Encoder::configured(codec, width, height, 8_000_000, 60).unwrap();
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut noise = || -> Vec<u8> {
            (0..width * height).flat_map(|_| {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
                [seed as u8, (seed >> 8) as u8, (seed >> 16) as u8, 255]
            }).collect()
        };
        let mut phase = |encoder: &mut Encoder, frames: usize| -> (usize, usize) {
            let (mut bytes, mut keys) = (0, 0);
            for index in 0..frames {
                let Some(packet) = encoder.encode(&noise(), false).unwrap() else { continue };
                // Rate control settles over the first frames of each phase.
                if index >= frames / 2 { bytes += packet.bytes.len(); }
                keys += usize::from(packet.key && index > 0);
            }
            (bytes, keys)
        };
        let (high, _) = phase(&mut encoder, 60);
        encoder.set_bitrate(800_000);
        let (low, keys) = phase(&mut encoder, 60);
        assert_eq!(keys, 0, "The rate change continues the stream without a keyframe");
        assert!(low * 3 < high, "Frames shrink with the live rate: {high} bytes before, {low} after");
    }

    /// VideoToolbox drops frames at a starved rate; low-delay encoding waits
    /// for each frame's output and must not wait forever for a dropped one.
    #[cfg(all(chromium_video, target_os = "macos"))]
    #[test]
    fn a_starved_rate_drops_frames_without_blocking() {
        let Some(&codec) = encoders(&[Codec::Hevc, Codec::H264]).first() else { return; };
        let (done, finished) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let (width, height) = (1280, 720);
            let mut encoder = Encoder::configured(codec, width, height, 8_000_000, 60).unwrap();
            encoder.set_bitrate(20_000);
            let mut seed = 0x9e37_79b9_7f4a_7c15u64;
            let mut packets = 0;
            for _ in 0..90 {
                let frame: Vec<u8> = (0..width * height).flat_map(|_| {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
                    [seed as u8, (seed >> 8) as u8, (seed >> 16) as u8, 255]
                }).collect();
                packets += usize::from(encoder.encode(&frame, false).unwrap().is_some());
            }
            let _ = done.send(packets);
        });
        let packets = finished.recv_timeout(std::time::Duration::from_secs(60)).expect("Encoding blocked on a dropped frame");
        assert!(packets > 0, "Some frames still reach the link");
        assert!(packets < 90, "The rate is starved enough that VideoToolbox drops frames");
    }

    #[test]
    fn preference_and_intersection() {
        assert_eq!(
            negotiate(&Codec::PREFERENCE, &Codec::PREFERENCE),
            Some(Codec::Av1)
        );
        assert_eq!(
            negotiate(&[Codec::H264, Codec::Hevc], &Codec::PREFERENCE),
            Some(Codec::Hevc)
        );
        assert_eq!(
            negotiate(&Codec::PREFERENCE, &[Codec::H264]),
            Some(Codec::H264)
        );
        assert_eq!(negotiate(&[Codec::Hevc], &[Codec::Av1]), None);
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn static_updates_are_delivered_without_another_input_frame() {
        if std::env::var_os("GRAFFITTY_VIDEO_TEST_REQUIRED").is_some() {
            assert!(!encoders(&Codec::PREFERENCE).is_empty(), "Hardware codec required");
        }
        for &codec in encoders(&Codec::PREFERENCE) {
            let mut encoder = Encoder::new(codec, 128, 96).unwrap();
            let mut decoder = Decoder::new(codec).unwrap();
            for color in [[20u8, 80, 160, 255], [180, 40, 20, 255]] {
                let pixels = color.repeat(128 * 96);
                let packet = encoder
                    .encode(&pixels, true)
                    .unwrap()
                    .expect("A static update must not wait for the next page change");
                let frame = decoder
                    .decode(&packet.bytes)
                    .unwrap()
                    .expect("An independent frame must be immediately decodable");
                for channel in 0..3 {
                    assert!((frame.rgba[channel] as i16 - color[channel] as i16).abs() < 20);
                }
            }
        }
    }
    #[test]
    fn hardware_roundtrip() {
        let required = std::env::var("GRAFFITTY_VIDEO_TEST_REQUIRED").as_deref() == Ok("1");
        let common: Vec<_> = encoders(&Codec::PREFERENCE)
            .iter()
            .filter(|c| decoders().contains(c))
            .copied()
            .collect();
        assert!(!required || !common.is_empty(), "No hardware codec tested");
        for codec in common {
            let mut encoder = Encoder::new(codec, 256, 192).unwrap();
            let mut decoder = Decoder::new(codec).unwrap();
            let mut count = 0;
            let mut keys = 0;
            for n in 0..12 {
                let mut rgba = vec![255; 256 * 192 * 4];
                for p in rgba.chunks_exact_mut(4) {
                    p[0] = 20 + n * 5;
                    p[1] = 80;
                    p[2] = 160;
                }
                if let Some(packet) = encoder.encode(&rgba, n == 0 || n == 6).unwrap() {
                    keys += usize::from(packet.key);
                    if packet.key {
                        decoder = Decoder::new(codec).unwrap();
                    }
                    if let Some(frame) = decoder.decode(&packet.bytes).unwrap() {
                        assert_eq!((frame.width, frame.height), (256, 192));
                        assert!((frame.rgba[1] as i16 - 80).abs() < 15);
                        assert!((frame.rgba[2] as i16 - 160).abs() < 15);
                        count += 1;
                    }
                }
            }
            assert!(count >= 8, "{codec:?} decoded {count} frames");
            assert!(keys >= 2, "{codec:?} did not honor recovery keyframe");
        }
    }
    #[test]
    fn nv12_frames_convert_like_rgba_frames() {
        let required = std::env::var("GRAFFITTY_VIDEO_TEST_REQUIRED").as_deref() == Ok("1");
        let common: Vec<_> = encoders(&Codec::PREFERENCE).iter().filter(|c| decoders().contains(c)).copied().collect();
        assert!(!required || !common.is_empty(), "No hardware codec tested");
        for codec in common {
            let mut encoder = Encoder::new(codec, 256, 192).unwrap();
            let (mut reference, mut planes) = (Decoder::new(codec).unwrap(), Decoder::new(codec).unwrap());
            let mut compared = 0;
            for n in 0..8u8 {
                let mut rgba = vec![255; 256 * 192 * 4];
                for p in rgba.chunks_exact_mut(4) {
                    p[..3].copy_from_slice(&[30 + n * 20, 120, 200 - n * 10]);
                }
                let Some(packet) = encoder.encode(&rgba, n == 0).unwrap() else { continue };
                let expected = reference.decode(&packet.bytes).unwrap();
                let Some(frame) = planes.decode_nv12(&packet.bytes).unwrap() else {
                    assert!(expected.is_none(), "{codec:?} formats must decode the same frames");
                    continue;
                };
                let expected = expected.expect("Both decoders receive the same packets");
                assert_eq!((frame.width, frame.height, frame.y.len(), frame.uv.len()), (256, 192, 256 * 192, 128 * 96 * 2));
                // The GPU conversion the Godot client applies: BT.601 limited range.
                let (y, u, v) = (frame.y[0] as f32, frame.uv[0] as f32 - 128.0, frame.uv[1] as f32 - 128.0);
                let luma = (y - 16.0) * 1.164_384;
                let rgb = [luma + 1.596_027 * v, luma - 0.391_762 * u - 0.812_968 * v, luma + 2.017_232 * u];
                for channel in 0..3 {
                    assert!((rgb[channel] - expected.rgba[channel] as f32).abs() < 6.0,
                        "{codec:?} NV12 {rgb:?} differs from RGBA {:?}", &expected.rgba[..3]);
                }
                compared += 1;
            }
            assert!(compared >= 4, "{codec:?} compared {compared} frames");
        }
    }
}

#[cfg(all(chromium_video, target_os = "macos"))]
pub mod surface;

#[cfg(all(chromium_video, target_os = "macos"))]
pub mod shared_gpu;

#[cfg(windows)]
#[path = "surface_windows.rs"]
pub mod surface;
#[cfg(windows)]
#[path = "shared_gpu_windows.rs"]
pub mod shared_gpu;

#[cfg(all(chromium_video, target_os = "linux"))]
#[path = "surface_linux.rs"]
pub mod surface;
