//! CEF host frames on Linux: Vulkan or CUDA external memory and sealed software frames.
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::OnceLock;
unsafe extern "C" {
    fn gl_capture_new(name: *const c_char, ptx: *const c_char) -> *mut c_void;
    fn gl_capture_free(p: *mut c_void);
    fn gl_capture_receive(p: *mut c_void, width: *mut u32, height: *mut u32) -> *mut c_void;
    fn gl_surface_clone(p: *mut c_void) -> *mut c_void;
    fn gl_surface_free(p: *mut c_void);
    fn gl_surface_is_software_paint(p: *mut c_void) -> bool;
    fn gl_surface_rgba(p: *mut c_void, out: *mut u8) -> i32;
    fn gl_video_probe_surface(ptx: *const c_char) -> *mut c_void;
    fn gl_video_minimum(surface: *mut c_void, codec: i32, width: *mut u32, height: *mut u32) -> i32;
    fn gl_video_new(
        surface: *mut c_void,
        codec: i32,
        width: i32,
        height: i32,
        bitrate: i32,
        fps: i32,
    ) -> *mut c_void;
    fn gl_video_free(encoder: *mut c_void);
    fn gl_video_set_bitrate(encoder: *mut c_void, bitrate: i32);
    fn gl_video_encode(
        encoder: *mut c_void,
        surface: *mut c_void,
        key: i32,
        bytes: *mut *const u8,
        is_key: *mut i32,
    ) -> i32;
    fn gl_video_stats(encoder: *mut c_void, frames: *mut u64, scaled: *mut u64, readbacks: *mut u64);
}

/// The GPU resampling kernel, loaded by the CUDA driver's PTX JIT.
fn scale_kernel() -> &'static CStr {
    static PTX: OnceLock<CString> = OnceLock::new();
    PTX.get_or_init(|| CString::new(include_str!("scale_linux.ptx")).expect("PTX has no NUL"))
}

pub struct Receiver(*mut c_void);
unsafe impl Send for Receiver {}
impl Receiver {
    pub fn new(name: &str) -> Result<Self, String> {
        let name = CString::new(name).map_err(|_| "Invalid capture endpoint")?;
        let p = unsafe { gl_capture_new(name.as_ptr(), scale_kernel().as_ptr()) };
        if p.is_null() {
            Err("Cannot create the Linux capture endpoint with the selected backend".into())
        } else {
            Ok(Self(p))
        }
    }
    pub fn receive(&mut self) -> Option<Surface> {
        let (mut width, mut height) = (0, 0);
        let handle = unsafe { gl_capture_receive(self.0, &mut width, &mut height) };
        (!handle.is_null()).then(|| Surface {
            handle,
            width,
            height,
        })
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        unsafe { gl_capture_free(self.0) };
    }
}

pub struct Surface {
    pub(crate) handle: *mut c_void,
    pub width: u32,
    pub height: u32,
}
unsafe impl Send for Surface {}
unsafe impl Sync for Surface {}
impl Clone for Surface {
    fn clone(&self) -> Self {
        Self {
            handle: unsafe { gl_surface_clone(self.handle) },
            width: self.width,
            height: self.height,
        }
    }
}
impl Drop for Surface {
    fn drop(&mut self) {
        unsafe { gl_surface_free(self.handle) };
    }
}
impl Surface {
    /// Whether the host supplied sealed CPU pixels for this frame.
    pub fn is_software_paint(&self) -> bool {
        unsafe { gl_surface_is_software_paint(self.handle) }
    }
    pub fn rgba(&self) -> Result<Vec<u8>, String> {
        let mut data = vec![0; self.width as usize * self.height as usize * 4];
        if unsafe { gl_surface_rgba(self.handle, data.as_mut_ptr()) } != 0 {
            return Err("Linux frame readback failed".into());
        }
        Ok(data)
    }
}

/// CUDA surfaces stay on the GPU. CPU-accessible surfaces use FFmpeg hardware upload.
pub struct SurfaceEncoder {
    handle: *mut c_void,
}
unsafe impl Send for SurfaceEncoder {}
impl SurfaceEncoder {
    /// Actual NVENC limits, rather than treating a tiny rendition as failure
    /// of an otherwise usable hardware codec.
    pub fn minimum_size(source: &Surface, codec: super::Codec) -> Option<(u32, u32)> {
        let (mut width, mut height) = (0, 0);
        (unsafe { gl_video_minimum(source.handle, codec as i32, &mut width, &mut height) } != 0)
            .then_some((width, height))
    }
    /// Bits per second for the next frames; NVENC applies it to the live
    /// session without a keyframe.
    pub fn set_bitrate(&mut self, bitrate: u32) {
        unsafe { gl_video_set_bitrate(self.handle, bitrate.min(200_000_000) as i32) };
    }
    pub fn configured(
        source: &Surface,
        codec: super::Codec,
        width: u32,
        height: u32,
        bitrate: u32,
        fps: u32,
    ) -> Result<Self, String> {
        if width < 16
            || height < 16
            || width > 4096
            || height > 4096
            || (width | height) & 1 != 0
            || bitrate > 200_000_000
            || !(1..=120).contains(&fps)
        {
            return Err("Invalid GPU video settings".into());
        }
        let handle = unsafe {
            gl_video_new(
                source.handle,
                codec as i32,
                width as i32,
                height as i32,
                bitrate as i32,
                fps as i32,
            )
        };
        if handle.is_null() {
            return Err("Hardware encoder unavailable for this surface and codec".into());
        }
        Ok(Self { handle })
    }
    pub fn encode(
        &mut self,
        source: &Surface,
        key: bool,
    ) -> Result<Option<super::Encoded>, String> {
        let (mut bytes, mut is_key) = (std::ptr::null(), 0);
        let size =
            unsafe { gl_video_encode(self.handle, source.handle, key.into(), &mut bytes, &mut is_key) };
        if size > 0 {
            return Ok(Some(super::Encoded {
                bytes: unsafe { std::slice::from_raw_parts(bytes, size as usize) }.to_vec(),
                key: is_key != 0,
            }));
        }
        if size == 0 {
            return Ok(None);
        }
        Err("Linux hardware encoding failed".into())
    }
    pub fn stats(&self) -> (u64, u64, u64) {
        let (mut frames, mut scaled, mut readbacks) = (0, 0, 0);
        unsafe { gl_video_stats(self.handle, &mut frames, &mut scaled, &mut readbacks) };
        (frames, scaled, readbacks)
    }
}
impl Drop for SurfaceEncoder {
    fn drop(&mut self) {
        unsafe { gl_video_free(self.handle) };
    }
}

pub(crate) fn probe_encoders(requested: &[super::Codec]) -> Vec<super::Codec> {
    let handle = unsafe { gl_video_probe_surface(scale_kernel().as_ptr()) };
    if handle.is_null() {
        return Vec::new();
    }
    let source = Surface { handle, width: 256, height: 256 };
    requested.iter().copied().filter(|&codec| {
        let Ok(mut encoder) = SurfaceEncoder::configured(&source, codec, 256, 256, 0, 60) else {
            return false;
        };
        // A static page may never send a second frame.
        matches!(encoder.encode(&source, true), Ok(Some(packet)) if packet.key)
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Codec, Decoder};
    unsafe extern "C" {
        fn gl_surface_from_rgba(
            ptx: *const c_char,
            width: u32,
            height: u32,
            data: *const u8,
            bgra: i32,
        ) -> *mut c_void;
    }
    fn fixture(width: u32, height: u32, color: [u8; 4], bgra: bool) -> Option<Surface> {
        let pixels = color.repeat((width * height) as usize);
        let handle = unsafe {
            gl_surface_from_rgba(scale_kernel().as_ptr(), width, height, pixels.as_ptr(), bgra.into())
        };
        (!handle.is_null()).then(|| Surface {
            handle,
            width,
            height,
        })
    }
    #[test]
    fn nvenc_cuda_frames_scale_and_deliver_static_updates_without_readback() {
        let required = std::env::var("GRAFFITTY_VIDEO_TEST_REQUIRED").as_deref() == Ok("1");
        let Some(probe) = fixture(16, 16, [0, 0, 0, 255], true) else {
            assert!(!required, "CUDA capture device required");
            eprintln!("No CUDA capture device; skipping");
            return;
        };
        let codecs = crate::encoders(&Codec::PREFERENCE);
        eprintln!("Linux hardware encoders={codecs:?}, decoders={:?}", crate::decoders());
        if required {
            assert!(codecs.contains(&Codec::H264), "NVIDIA H.264 hardware encoder required");
        }
        for &codec in codecs {
            let minimum = SurfaceEncoder::minimum_size(&probe, codec)
                .expect("NVENC must report its minimum dimensions");
            eprintln!("{codec:?} minimum={minimum:?}");
            for bgra in [true, false] {
                let source = fixture(256, 192, [20, 80, 160, 255], bgra).unwrap();
                let mut encoder = SurfaceEncoder::configured(&source, codec, 256, 192, 0, 60).unwrap();
                let retained = source.clone();
                drop(source);
                let mut decoder = Decoder::new(codec).unwrap();
                for n in 0..24 {
                    let color = if n % 2 == 0 { [20, 80, 160, 255] } else { [180, 40, 20, 255] };
                    // Odd source dimensions and downscaling use the CUDA kernel.
                    let (width, height) = if n < 8 { (256, 192) } else { (513, 387) };
                    let frame = fixture(width, height, color, bgra).unwrap();
                    let force_key = n == 0 || n == 12;
                    let packet = encoder
                        .encode(&frame, force_key)
                        .unwrap()
                        .expect("A static update must arrive without another input frame");
                    if force_key {
                        assert!(packet.key, "Recovery keyframe was ignored");
                        decoder = Decoder::new(codec).unwrap();
                    }
                    let decoded = decoder
                        .decode(&packet.bytes)
                        .unwrap()
                        .expect("Hardware decoder must present each update");
                    assert_eq!((decoded.width, decoded.height), (256, 192));
                    for (x, y) in [(2, 2), (128, 96), (253, 189)] {
                        let index = (y * 256 + x) * 4;
                        for channel in 0..3 {
                            assert!(
                                (decoded.rgba[index + channel] as i16 - color[channel] as i16).abs() < 20,
                                "{codec:?} bgra={bgra} frame={n} pixel={:?} expected={color:?}",
                                &decoded.rgba[index..index + 4]
                            );
                        }
                        assert_eq!(decoded.rgba[index + 3], 255);
                    }
                }
                drop(retained);
                assert_eq!(encoder.stats(), (24, 16, 0), "Encoding must use GPU scaling and zero CPU readbacks");
            }
        }
    }
    #[test]
    fn receiver_owns_its_endpoint_and_waits_without_a_host() {
        let name = format!("graffitty-test-{}", std::process::id());
        let mut receiver = Receiver::new(&name).unwrap();
        assert!(receiver.receive().is_none(), "No frame arrives before a host connects");
        assert!(Receiver::new(&name).is_err(), "A live endpoint name cannot be taken twice");
        drop(receiver);
        Receiver::new(&name).expect("A dropped receiver releases its endpoint");
    }
    #[test]
    fn receiver_imports_exported_vulkan_frames() {
        // tests/platform/linux/linux_vulkan_producer.cpp exports frames exactly as the CEF host
        // does, then frees its allocation; see docs/developers/internals/linux-chromium.md.
        let Some(producer) = std::env::var_os("GRAFFITTY_GPU_TEST_PRODUCER") else {
            eprintln!("Set GRAFFITTY_GPU_TEST_PRODUCER to run the Vulkan import check");
            return;
        };
        let name = format!("graffitty-producer-test-{}", std::process::id());
        let mut receiver = Receiver::new(&name).unwrap();
        let mut child = std::process::Command::new(producer).arg(&name).spawn().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        let mut received = 0;
        while received < 64 && std::time::Instant::now() < deadline {
            let Some(surface) = receiver.receive() else {
                std::thread::sleep(std::time::Duration::from_millis(1));
                continue;
            };
            received += 1;
            assert_eq!((surface.width, surface.height), (80 + received, 64 + received));
            assert!(!surface.is_software_paint());
            if received <= 2 && std::env::var("GRAFFITTY_CAPTURE").as_deref() == Ok("vulkan") {
                for &codec in crate::encoders(&Codec::PREFERENCE) {
                    let mut encoder = SurfaceEncoder::configured(&surface, codec, 256, 192, 0, 60).unwrap();
                    let packet = encoder.encode(&surface, true).unwrap().expect("Vulkan static update");
                    assert!(packet.key);
                    assert_eq!(encoder.stats(), (1, 1, 1));
                    if crate::decoders().contains(&codec) {
                        let frame = Decoder::new(codec).unwrap().decode(&packet.bytes).unwrap().unwrap();
                        assert_eq!((frame.width, frame.height), (256, 192));
                        for (value, expected) in frame.rgba[..3].iter().zip([0x33i16, 0x66, 0xcc]) {
                            assert!((i16::from(*value) - expected).abs() < 20);
                        }
                    }
                }
            }
            let rgba = surface.rgba().unwrap();
            assert!(
                rgba.chunks(4).all(|pixel| pixel == [0x33, 0x66, 0xcc, 0xff]),
                "frame {received} starts with {:?}",
                &rgba[..4]
            );
        }
        assert_eq!(received, 64, "Every exported frame must arrive");
        assert!(child.wait().unwrap().success());
    }
    #[test]
    fn sealed_frames_validate_descriptors_and_encode_scaled_bgra() {
        let name = format!("graffitty-memfd-test-{}", std::process::id());
        let mut receiver = Receiver::new(&name).unwrap();
        let mut producer = std::process::Command::new("python3")
            .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/linux_memfd_producer.py"))
            .arg(&name)
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        let mut received = Vec::new();
        loop {
            if let Some(surface) = receiver.receive() {
                received.push(surface);
            }
            if let Some(status) = producer.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        drop(receiver);
        assert_eq!(received.len(), 1, "Only the sealed, exact-sized descriptor is valid");
        let surface = received.pop().unwrap();
        assert!(surface.is_software_paint());
        assert_eq!((surface.width, surface.height), (257, 193));
        assert!(surface.rgba().unwrap().chunks_exact(4).all(|p| p == [32, 120, 200, 255]));
        for &codec in crate::encoders(&Codec::PREFERENCE) {
            let mut encoder = SurfaceEncoder::configured(&surface, codec, 256, 192, 0, 60).unwrap();
            let packet = encoder.encode(&surface, true).unwrap().expect("static page keyframe");
            assert!(packet.key);
            assert_eq!(encoder.stats(), (1, 1, 0));
            if crate::decoders().contains(&codec) {
                let decoded = Decoder::new(codec).unwrap().decode(&packet.bytes).unwrap().unwrap();
                assert_eq!((decoded.width, decoded.height), (256, 192));
                for (actual, expected) in decoded.rgba[..3].iter().zip([32i16, 120, 200]) {
                    assert!((i16::from(*actual) - expected).abs() < 20);
                }
            }
        }
    }

    #[test]
    fn diagnostic_readback_returns_rgba_for_both_channel_orders() {
        for bgra in [true, false] {
            let Some(surface) = fixture(17, 9, [200, 100, 50, 255], bgra) else {
                eprintln!("No CUDA capture device; skipping");
                return;
            };
            let pixels = surface.rgba().unwrap();
            assert_eq!(pixels.len(), 17 * 9 * 4);
            assert!(pixels.chunks(4).all(|p| p == [200, 100, 50, 255]), "bgra={bgra}");
        }
    }
}
