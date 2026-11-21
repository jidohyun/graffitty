//! Immutable D3D11 textures retained across native capture and client imports.
use std::ffi::{CString, c_void};
unsafe extern "C" {
    fn gw_video_minimum(surface: *mut c_void, codec: i32, width: *mut u32, height: *mut u32) -> i32;
    fn gw_capture_new(name: *const i8) -> *mut c_void;
    fn gw_capture_free(p: *mut c_void);
    fn gw_capture_receive(p: *mut c_void, width: *mut u32, height: *mut u32) -> *mut c_void;
    fn gw_surface_clone(p: *mut c_void) -> *mut c_void;
    fn gw_surface_free(p: *mut c_void);
    fn gw_surface_rgba(p: *mut c_void, out: *mut u8) -> i32;
}
unsafe extern "C" {
    fn gw_surface_from_rgba(
        reference: *mut c_void,
        width: u32,
        height: u32,
        data: *const u8,
        bgra: i32,
    ) -> *mut c_void;
}

pub(super) fn probe_encoders(requested: &[super::Codec]) -> Vec<super::Codec> {
    let pixels = vec![96; 256 * 256 * 4];
    let handle = unsafe { gw_surface_from_rgba(std::ptr::null_mut(), 256, 256, pixels.as_ptr(), 1) };
    if handle.is_null() {
        return Vec::new();
    }
    let surface = Surface { handle, width: 256, height: 256 };
    requested.iter().copied().filter(|&codec| {
        // Configuration submits a real texture and requires a key packet.
        SurfaceEncoder::configured(&surface, codec, 256, 256, 0, 60).is_ok()
    }).collect()
}

pub struct Receiver(*mut c_void);
unsafe impl Send for Receiver {}
impl Receiver {
    pub fn new(name: &str) -> Result<Self, String> {
        let name = CString::new(name).map_err(|_| "Invalid capture endpoint")?;
        let p = unsafe { gw_capture_new(name.as_ptr()) };
        if p.is_null() {
            Err("Cannot create D3D capture endpoint".into())
        } else {
            Ok(Self(p))
        }
    }
    pub fn receive(&mut self) -> Option<Surface> {
        let (mut width, mut height) = (0, 0);
        let handle = unsafe { gw_capture_receive(self.0, &mut width, &mut height) };
        (!handle.is_null()).then_some(Surface {
            handle,
            width,
            height,
        })
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        unsafe { gw_capture_free(self.0) };
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
            handle: unsafe { gw_surface_clone(self.handle) },
            width: self.width,
            height: self.height,
        }
    }
}
impl Drop for Surface {
    fn drop(&mut self) {
        unsafe { gw_surface_free(self.handle) };
    }
}
impl Surface {
    pub fn rgba(&self) -> Result<Vec<u8>, String> {
        let mut data = vec![0; self.width as usize * self.height as usize * 4];
        if unsafe { gw_surface_rgba(self.handle, data.as_mut_ptr()) } != 0 {
            return Err("D3D diagnostic readback failed".into());
        }
        Ok(data)
    }
}

/// Hardware encoders consume pooled D3D11 textures on the capture adapter. Scaling and
/// copies stay on the GPU; PNG readback remains a separate compatibility path.
pub struct SurfaceEncoder {
    #[cfg(chromium_video)]
    handle: *mut c_void,
}
unsafe impl Send for SurfaceEncoder {}
#[cfg(chromium_video)]
unsafe extern "C" {
    fn gw_video_new(
        surface: *mut c_void,
        codec: i32,
        width: i32,
        height: i32,
        bitrate: i32,
        fps: i32,
    ) -> *mut c_void;
    fn gw_video_free(encoder: *mut c_void);
    fn gw_video_set_bitrate(encoder: *mut c_void, bitrate: i32);
    fn gw_video_encode(
        encoder: *mut c_void,
        surface: *mut c_void,
        key: i32,
        bytes: *mut *const u8,
        is_key: *mut i32,
    ) -> i32;
    fn gw_video_stats(
        encoder: *mut c_void,
        frames: *mut u64,
        scaled: *mut u64,
        readbacks: *mut u64,
    );
}
impl SurfaceEncoder {
    /// Actual adapter limits, rather than treating a tiny rendition as failure
    /// of an otherwise usable hardware codec.
    pub fn minimum_size(source: &Surface, codec: super::Codec) -> Option<(u32, u32)> {
        #[cfg(chromium_video)]
        {
            let (mut width, mut height) = (0, 0);
            if unsafe { gw_video_minimum(source.handle, codec as i32, &mut width, &mut height) } != 0 {
                return Some((width, height));
            }
        }
        let _ = (source, codec);
        None
    }
    /// Bits per second for the next frames; NVENC applies it to the live
    /// session without a keyframe.
    pub fn set_bitrate(&mut self, bitrate: u32) {
        // Without the video libraries there is no encoder to tell.
        #[cfg(chromium_video)]
        unsafe {
            gw_video_set_bitrate(self.handle, bitrate.min(200_000_000) as i32)
        };
        let _ = bitrate;
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
        #[cfg(chromium_video)]
        {
            let handle = unsafe {
                gw_video_new(
                    source.handle,
                    codec as i32,
                    width as i32,
                    height as i32,
                    bitrate as i32,
                    fps as i32,
                )
            };
            if !handle.is_null() {
                return Ok(Self { handle });
            }
        }
        let _ = (source, codec);
        Err("D3D11 hardware encoder unavailable for this adapter/codec".into())
    }
    pub fn encode(
        &mut self,
        source: &Surface,
        key: bool,
    ) -> Result<Option<super::Encoded>, String> {
        #[cfg(chromium_video)]
        {
            let (mut bytes, mut is_key) = (std::ptr::null(), 0);
            let size = unsafe {
                gw_video_encode(
                    self.handle,
                    source.handle,
                    key.into(),
                    &mut bytes,
                    &mut is_key,
                )
            };
            if size > 0 {
                return Ok(Some(super::Encoded {
                    bytes: unsafe { std::slice::from_raw_parts(bytes, size as usize) }.to_vec(),
                    key: is_key != 0,
                }));
            }
            if size == 0 {
                return Ok(None);
            }
        }
        let _ = (source, key);
        Err("D3D11 hardware encoding failed".into())
    }
    pub fn stats(&self) -> (u64, u64, u64) {
        #[cfg(chromium_video)]
        {
            let (mut frames, mut scaled, mut readbacks) = (0, 0, 0);
            unsafe {
                gw_video_stats(self.handle, &mut frames, &mut scaled, &mut readbacks);
            }
            return (frames, scaled, readbacks);
        }
        #[cfg(not(chromium_video))]
        (0, 0, 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Codec, Decoder};
    fn fixture(
        reference: Option<&Surface>,
        width: u32,
        height: u32,
        color: [u8; 4],
        bgra: bool,
    ) -> Surface {
        let pixels = color.repeat((width * height) as usize);
        let handle = unsafe {
            gw_surface_from_rgba(
                reference.map_or(std::ptr::null_mut(), |s| s.handle),
                width,
                height,
                pixels.as_ptr(),
                bgra.into(),
            )
        };
        assert!(!handle.is_null(), "D3D11 fixture texture allocation failed");
        Surface {
            handle,
            width,
            height,
        }
    }
    #[test]
    fn gpu_textures_scale_and_deliver_static_updates_without_readback() {
        let codecs = crate::encoders(&Codec::PREFERENCE);
        eprintln!(
            "Windows hardware encoders={codecs:?}, decoders={:?}",
            crate::decoders()
        );
        if std::env::var("GRAFFITTY_VIDEO_TEST_REQUIRED").as_deref() == Ok("1") {
            assert!(
                codecs.contains(&Codec::H264),
                "D3D11 H.264 hardware encoder required"
            );
        }
        for &codec in codecs {
            let source = fixture(None, 256, 256, [20, 80, 160, 255], true);
            let minimum = SurfaceEncoder::minimum_size(&source, codec)
                .expect("Hardware encoder must report its minimum dimensions");
            eprintln!("{codec:?} minimum={minimum:?}");
            let mut smallest = SurfaceEncoder::configured(
                &source, codec, (minimum.0 + 1) & !1, (minimum.1 + 1) & !1, 0, 60,
            ).unwrap();
            assert!(smallest.encode(&source, true).unwrap().is_some(),
                "An overview rendition at the adapter's minimum must encode");
            assert_eq!(smallest.stats().2, 0, "Minimum-size scaling stays on the GPU");
            drop(smallest);
            for bgra in [true, false] {
                let source = fixture(None, 256, 192, [20, 80, 160, 255], bgra);
                let mut encoder =
                    SurfaceEncoder::configured(&source, codec, 256, 192, 0, 60).unwrap();
                // Retaining a texture must retain its device after capture ends.
                let retained = source.clone();
                drop(source);
                let mut decoder = Decoder::new(codec).unwrap();
                for n in 0..24 {
                    let color = if n % 2 == 0 {
                        [20, 80, 160, 255]
                    } else {
                        [180, 40, 20, 255]
                    };
                    // Odd source dimensions and downscaling use the video processor.
                    let (width, height) = if n < 8 { (256, 192) } else { (513, 387) };
                    let frame = fixture(Some(&retained), width, height, color, bgra);
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
                                (decoded.rgba[index + channel] as i16 - color[channel] as i16)
                                    .abs()
                                    < 20,
                                "{codec:?} bgra={bgra} frame={n} pixel={:?} expected={color:?}",
                                &decoded.rgba[index..index + 4]
                            );
                        }
                        assert_eq!(decoded.rgba[index + 3], 255);
                    }
                }
                assert_eq!(
                    encoder.stats(),
                    (24, 16, 0),
                    "Encoding must use GPU scaling and zero CPU readbacks"
                );
            }
        }
    }
}
impl Drop for SurfaceEncoder {
    fn drop(&mut self) {
        #[cfg(chromium_video)]
        unsafe {
            gw_video_free(self.handle);
        }
    }
}
