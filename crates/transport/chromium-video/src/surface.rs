//! Immutable CEF IOSurfaces, retained through asynchronous hardware encoding.
use super::{Codec, Encoded, native::Handle};
use std::ffi::{CString, c_void};
unsafe extern "C" {
    fn gv_surface_from_rgba(width: u32, height: u32, data: *const u8) -> *mut c_void;
    fn gv_surface_scale(surface: *mut c_void, width: u32, height: u32) -> *mut c_void;
    fn gv_surface_crop(surface: *mut c_void, width: u32, height: u32) -> *mut c_void;
    fn gv_receiver_new(name: *const std::ffi::c_char) -> *mut c_void;
    fn gv_receiver_free(receiver: *mut c_void);
    fn gv_surface_receive(receiver: *mut c_void, width: *mut u32, height: *mut u32) -> *mut c_void;
    fn gv_surface_free(surface: *mut c_void);
    fn gv_surface_rgba(surface: *mut c_void, out: *mut u8) -> i32;
    fn gv_surface_encoder(codec: i32, width: i32, height: i32, bitrate: i32, fps: i32) -> *mut c_void;
    fn gv_set_bitrate(video: *mut c_void, bitrate: i32);
    fn gv_encode_surface(
        video: *mut c_void,
        surface: *mut c_void,
        key: i32,
        bytes: *mut *const u8,
        is_key: *mut i32,
    ) -> i32;
}
pub struct Receiver(*mut c_void);
unsafe impl Send for Receiver {}
impl Receiver {
    pub fn new(name: &str) -> Result<Self, String> {
        let name = CString::new(name).map_err(|_| "Invalid surface endpoint")?;
        let p = unsafe { gv_receiver_new(name.as_ptr()) };
        if p.is_null() {
            Err("Cannot register GPU surface endpoint".into())
        } else {
            Ok(Self(p))
        }
    }
    pub fn receive(&mut self) -> Option<Surface> {
        let (mut width, mut height) = (0, 0);
        let p = unsafe { gv_surface_receive(self.0, &mut width, &mut height) };
        (!p.is_null()).then(|| Surface {
            handle: p,
            width,
            height,
        })
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        unsafe { gv_receiver_free(self.0) };
    }
}
pub struct Surface {
    pub(crate) handle: *mut c_void,
    pub width: u32,
    pub height: u32,
}
// Sender copies each capture into a new surface and waits for the GPU copy.
// Receivers only read it. The reference owns its lifetime across all renditions.
unsafe impl Send for Surface {}
unsafe impl Sync for Surface {}
impl Drop for Surface {
    fn drop(&mut self) {
        unsafe { gv_surface_free(self.handle) };
    }
}
impl Surface {
    /// Hardware chroma planes require even dimensions. Crop only the final
    /// row/column on the GPU; local imports retain the full original surface.
    pub fn video_aligned(&self) -> Result<Self, String> {
        let (width,height)=(self.width & !1,self.height & !1);
        if (width,height)==(self.width,self.height) {return Ok(self.clone());}
        if width<16 || height<16 {return Err("Video surface is too small".into());}
        let handle=unsafe {gv_surface_crop(self.handle,width,height)};
        if handle.is_null() {return Err("GPU video surface alignment failed".into());}
        Ok(Self {handle,width,height})
    }

    pub fn scaled(&self, width: u32, height: u32) -> Result<Self, String> {
        if (width,height)==(self.width,self.height) { return Ok(self.clone()); }
        if width<16 || height<16 || width>self.width || height>self.height { return Err("Invalid scaled surface dimensions".into()); }
        let handle=unsafe {gv_surface_scale(self.handle,width,height)};
        if handle.is_null() {return Err("GPU video scaling failed".into());}
        Ok(Self {handle,width,height})
    }

    /// Populate an immutable shared resource once. All local clients import
    /// this same storage; subsequent placements never copy these pixels.
    pub fn from_rgba(width: u32, height: u32, data: &[u8]) -> Result<Self, String> {
        if width == 0 || height == 0 || width > 8192 || height > 8192 || data.len() != width as usize * height as usize * 4 {
            return Err("Invalid shared image dimensions".into());
        }
        let handle = unsafe { gv_surface_from_rgba(width, height, data.as_ptr()) };
        if handle.is_null() { return Err("Shared image allocation failed".into()) }
        Ok(Self { handle, width, height })
    }
    pub fn rgba(&self) -> Result<Vec<u8>, String> {
        let mut data = vec![0; self.width as usize * self.height as usize * 4];
        if unsafe { gv_surface_rgba(self.handle, data.as_mut_ptr()) } != 0 {
            return Err("GPU compatibility readback failed".into());
        }
        Ok(data)
    }
}

#[cfg(test)]
mod immutable_image_tests {
    use super::*;
    #[test]
    fn hardware_surface_colors_match_client_nv12_conversion() {
        let codecs = crate::encoders(&Codec::PREFERENCE);
        if std::env::var_os("GRAFFITTY_VIDEO_TEST_REQUIRED").is_some() { assert!(!codecs.is_empty()); }
        for &codec in codecs {
            for (width, height) in [(128, 96), (564, 1440)] {
                let mut encoder = SurfaceEncoder::new(codec, width, height).unwrap();
                for color in [[20, 80, 160, 255], [160, 80, 20, 255], [20, 160, 80, 255], [128, 128, 128, 255]] {
                    let surface = Surface::from_rgba(width, height, &color.repeat((width * height) as usize)).unwrap();
                    let packet = encoder.encode(&surface, true).unwrap().expect("Static colour must encode immediately");
                    if let Some(directory) = std::env::var_os("GRAFFITTY_VIDEO_TEST_ARTIFACTS") {
                        let directory = std::path::PathBuf::from(directory);
                        std::fs::create_dir_all(&directory).unwrap();
                        std::fs::write(directory.join(format!("{codec:?}-{width}-{height}-{}-{}-{}.bin", color[0], color[1], color[2])), &packet.bytes).unwrap();
                    }
                    let mut decoder = crate::Decoder::new(codec).unwrap();
                    let frame = decoder.decode_nv12(&packet.bytes).unwrap().expect("Keyframe must decode immediately");
                    let (y, u, v) = (frame.y[0] as f32, frame.uv[0] as f32 - 128.0, frame.uv[1] as f32 - 128.0);
                    let luma = (y - 16.0) * 1.164_384;
                    let rgb = [luma + 1.596_027 * v, luma - 0.391_762 * u - 0.812_968 * v, luma + 2.017_232 * u];
                    for channel in 0..3 {
                        assert!((rgb[channel] - color[channel] as f32).abs() < 8.0,
                            "{codec:?} {width}x{height}: expected {color:?}, client decoded {rgb:?}");
                    }
                }
            }
        }
    }
    #[test]
    fn scaled_surface_preserves_the_full_image() {
        let mut pixels=Vec::new();
        for _ in 0..128 {for x in 0..256 {pixels.extend_from_slice(if x<128 {&[255,0,0,255]} else {&[0,0,255,255]});}}
        let original=Surface::from_rgba(256,128,&pixels).unwrap();
        let scaled=original.scaled(128,64).unwrap();
        assert_eq!((scaled.width,scaled.height),(128,64));
        let result=scaled.rgba().unwrap();
        assert_eq!(&result[..4],&[255,0,0,255]);
        assert_eq!(&result[result.len()-4..],&[0,0,255,255]);
        assert_eq!(original.rgba().unwrap(),pixels);
    }
    #[test]
    fn odd_video_surfaces_crop_on_gpu_without_changing_local_imports() {
        let (width,height)=(129,97);
        let color=[20,80,160,255];
        let original=Surface::from_rgba(width,height,&color.repeat((width*height) as usize)).unwrap();
        let aligned=original.video_aligned().unwrap();
        assert_eq!((original.width,original.height),(129,97));
        assert_eq!((aligned.width,aligned.height),(128,96));
        assert_eq!(aligned.rgba().unwrap(),color.repeat(128*96));
        let codecs=crate::encoders(&Codec::PREFERENCE);
        if std::env::var_os("GRAFFITTY_VIDEO_TEST_REQUIRED").is_some() {assert!(!codecs.is_empty());}
        for &codec in codecs {
            let mut encoder=SurfaceEncoder::new(codec,aligned.width,aligned.height).unwrap();
            let packet=encoder.encode(&aligned,true).unwrap().expect("Static odd-size update must produce a packet");
            let mut decoder=crate::Decoder::new(codec).unwrap();
            let frame=decoder.decode(&packet.bytes).unwrap().expect("Keyframe must decode");
            assert_eq!((frame.width,frame.height),(128,96));
            for (actual,expected) in frame.rgba.chunks_exact(4).next().unwrap()[..3].iter().zip(color) {
                assert!((*actual as i16-expected as i16).abs()<12);
            }
        }
        assert_eq!(original.rgba().unwrap(),color.repeat((width*height) as usize));
    }
    #[test]
    fn small_and_odd_rgba_assets_survive_native_import_and_producer_release() {
        let device = crate::shared_gpu::ProbeDevice::new().unwrap();
        for (width, height) in [(1, 1), (17, 9)] {
            let rgba = [240, 30, 50, 128].repeat(width as usize * height as usize);
            let surface = Surface::from_rgba(width, height, &rgba).unwrap();
            let retained = surface.clone();
            drop(surface);
            assert_eq!(retained.rgba().unwrap(), rgba);
            let sample = unsafe { retained.sample_bgra(device.as_ptr(), 0, 0, 1) }.unwrap();
            assert_eq!(sample, [50, 30, 240, 128]);
        }
    }
}
pub struct SurfaceEncoder {
    handle: Handle,
    width: u32,
    height: u32,
}
impl SurfaceEncoder {
    pub fn new(codec: Codec, width: u32, height: u32) -> Result<Self, String> {
        Self::configured(codec, width, height, 0, 60)
    }
    pub fn configured(codec: Codec, width: u32, height: u32, bitrate: u32, fps: u32) -> Result<Self, String> {
        if bitrate > 200_000_000 || !(1..=120).contains(&fps) { return Err("Invalid video encoding settings".into()); }
        let p = unsafe { gv_surface_encoder(codec as i32, width as i32, height as i32, bitrate as i32, fps as i32) };
        if p.is_null() {
            return Err("Hardware surface encoder unavailable".into());
        }
        Ok(Self {
            handle: Handle(p),
            width,
            height,
        })
    }
    /// Bits per second for the next frames; VideoToolbox applies it to the
    /// live session without a keyframe.
    pub fn set_bitrate(&mut self, bitrate: u32) {
        unsafe { gv_set_bitrate(self.handle.0, bitrate.min(200_000_000) as i32) };
    }
    pub fn encode(&mut self, surface: &Surface, key: bool) -> Result<Option<Encoded>, String> {
        if (surface.width, surface.height) != (self.width, self.height) {
            return Err("GPU surface size changed".into());
        }
        let (mut bytes, mut is_key) = (std::ptr::null(), 0);
        let n = unsafe {
            gv_encode_surface(
                self.handle.0,
                surface.handle,
                key.into(),
                &mut bytes,
                &mut is_key,
            )
        };
        if n < 0 {
            return Err("Hardware surface encode failed".into());
        }
        Ok((n > 0).then(|| Encoded {
            bytes: unsafe { std::slice::from_raw_parts(bytes, n as usize) }.to_vec(),
            key: is_key != 0,
        }))
    }
}

unsafe extern "C" {
    fn gg_surface_texture(surface: *mut c_void, device: *mut c_void) -> *mut c_void;
    fn gg_surface_sample(
        surface: *mut c_void,
        device: *mut c_void,
        x: u32,
        y: u32,
        count: u32,
        out: *mut u8,
    ) -> i32;
    fn CFRetain(value: *const c_void) -> *const c_void;
}
impl Clone for Surface {
    fn clone(&self) -> Self {
        unsafe {
            CFRetain(self.handle);
        }
        Self {
            handle: self.handle,
            width: self.width,
            height: self.height,
        }
    }
}
impl Surface {
    /// Import without copying or decoding pixels. Returns an owned (+1) native
    /// BGRA8Unorm MTLTexture; the renderer must transfer/release that reference.
    /// # Safety
    /// `device` must be a live MTLDevice.
    pub unsafe fn metal_texture(&self, device: *mut c_void) -> Result<*mut c_void, String> {
        let texture = unsafe { gg_surface_texture(self.handle, device) };
        if texture.is_null() {
            Err("IOSurface Metal import failed".into())
        } else {
            Ok(texture)
        }
    }
    /// GPU readback used only by probe/conformance checks, never frame delivery.
    /// Returns native BGRA bytes.
    /// # Safety
    /// `device` must be a live MTLDevice.
    pub unsafe fn sample_bgra(
        &self,
        device: *mut c_void,
        x: u32,
        y: u32,
        count: u32,
    ) -> Result<Vec<u8>, String> {
        if count == 0 || x.checked_add(count).is_none_or(|end| end > self.width) || y >= self.height
        {
            return Err("GPU sample is outside the texture".into());
        }
        let mut bytes = vec![0; count as usize * 4];
        if unsafe { gg_surface_sample(self.handle, device, x, y, count, bytes.as_mut_ptr()) } != 0 {
            return Err("GPU texture sampling failed".into());
        }
        Ok(bytes)
    }
}
