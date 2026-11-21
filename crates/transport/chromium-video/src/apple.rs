//! Apple hardware decoding. The wire stays Annex-B; only this adapter converts
//! access units to CoreMedia's length-prefixed samples. No FFmpeg on iOS.
use crate::{Codec, DecodeError};
use std::{ffi::c_void, ptr::NonNull};

unsafe extern "C" {
    fn gvi_new(codec: i32) -> *mut c_void;
    fn gvi_free(decoder: *mut c_void);
    fn gvi_configure(decoder: *mut c_void, codec: i32, sets: *const *const u8, sizes: *const usize, count: usize) -> i32;
    fn gvi_decode(decoder: *mut c_void, bytes: *const u8, length: usize, layout: i32,
                  pixels: *mut *const u8, width: *mut i32, height: *mut i32) -> i32;
}
const BAD_PACKET: DecodeError = DecodeError::Failure("Invalid Annex-B video access unit");
const FAILED: DecodeError = DecodeError::Failure("Hardware VideoToolbox decoder already failed");
const MAX_PACKET: usize = 8 * 1024 * 1024;
const MAX_PARAMETER: usize = 64 * 1024;

fn start_code(bytes: &[u8], at: usize) -> Option<usize> {
    if bytes.get(at..at+3) == Some(&[0, 0, 1]) { Some(3) }
    else if bytes.get(at..at+4) == Some(&[0, 0, 0, 1]) { Some(4) }
    else { None }
}
fn nals(bytes: &[u8]) -> Result<Vec<&[u8]>, DecodeError> {
    if bytes.is_empty() || bytes.len() > MAX_PACKET { return Err(BAD_PACKET); }
    let mut result = Vec::new();
    let mut start = None;
    let mut i = 0;
    while i < bytes.len() {
        if let Some(length) = start_code(bytes, i) {
            if let Some(begin) = start {
                let mut end = i;
                while end > begin && bytes[end-1] == 0 { end -= 1; }
                if end == begin { return Err(BAD_PACKET); }
                result.push(&bytes[begin..end]);
                if result.len() >= 256 { return Err(BAD_PACKET); }
            } else if bytes[..i].iter().any(|&b| b != 0) { return Err(BAD_PACKET); }
            i += length;
            start = Some(i);
        } else { i += 1; }
    }
    let begin = start.ok_or(BAD_PACKET)?;
    let mut end = bytes.len();
    while end > begin && bytes[end-1] == 0 { end -= 1; }
    if begin == end { return Err(BAD_PACKET); }
    result.push(&bytes[begin..end]);
    Ok(result)
}
/// A NAL's parameter-set slot (H.264: SPS, PPS; HEVC: VPS, SPS, PPS) and
/// whether it carries picture data. Malformed or unsupported headers are errors.
fn classify(codec: Codec, nal: &[u8]) -> Result<(Option<usize>, bool), DecodeError> {
    if nal[0] & 0x80 != 0 { return Err(BAD_PACKET); }
    match codec {
        Codec::H264 => {
            let kind = nal[0] & 31;
            if kind == 0 || kind > 23 { return Err(BAD_PACKET); }
            Ok((match kind { 7 => Some(0), 8 => Some(1), _ => None }, (1..=5).contains(&kind)))
        }
        Codec::Hevc => {
            if nal.len() < 2 || nal[1] & 7 == 0 { return Err(BAD_PACKET); }
            let kind = (nal[0] >> 1) & 63;
            Ok((match kind { 32..=34 => Some((kind-32) as usize), _ => None }, kind <= 31))
        }
        Codec::Av1 => Err(BAD_PACKET),
    }
}

#[derive(Default)]
struct Parameters {
    sets: [Vec<u8>; 3],
}
struct Packet {
    sample: Vec<u8>,
    changed: bool,
    picture: bool,
}
impl Parameters {
    fn prepare(&mut self, codec: Codec, bytes: &[u8]) -> Result<Packet, DecodeError> {
        let mut packet = Packet { sample: Vec::with_capacity(bytes.len()), changed: false, picture: false };
        for nal in nals(bytes)? {
            let (slot, picture) = classify(codec, nal)?;
            if let Some(slot) = slot {
                if nal.len() > MAX_PARAMETER { return Err(BAD_PACKET); }
                if self.sets[slot] != nal {
                    self.sets[slot] = nal.to_vec();
                    packet.changed = true;
                }
            }
            packet.picture |= picture;
            packet.sample.extend_from_slice(&(nal.len() as u32).to_be_bytes());
            packet.sample.extend_from_slice(nal);
        }
        if packet.sample.len() > MAX_PACKET { return Err(BAD_PACKET); }
        Ok(packet)
    }
    fn complete(&self, codec: Codec) -> bool {
        self.sets[..if codec == Codec::H264 { 2 } else { 3 }].iter().all(|s| !s.is_empty())
    }
}

pub struct Decoder {
    handle: NonNull<c_void>,
    codec: Codec,
    parameters: Parameters,
    configured: bool,
    /// A failed call may have dropped a reference picture, so every later call
    /// fails too: the caller discards the decoder and renegotiates.
    failed: bool,
}
// The handle and all VideoToolbox work belong exclusively to one decoder worker.
unsafe impl Send for Decoder {}
impl Decoder {
    pub fn new(codec: Codec, name: &str, width: u32, height: u32) -> Result<Self, String> {
        if !matches!(name, "" | "videotoolbox") || width > 8192 || height > 8192
            || u64::from(width) * u64::from(height) > 16 * 1024 * 1024 {
            return Err("Invalid VideoToolbox configuration".into());
        }
        let handle = NonNull::new(unsafe { gvi_new(codec as i32) }).ok_or("Hardware VideoToolbox decoder unavailable")?;
        Ok(Self { handle, codec, parameters: Parameters::default(), configured: false, failed: false })
    }
    pub fn frame(&mut self, bytes: &[u8], layout: i32) -> Result<Option<(&[u8], u32, u32)>, DecodeError> {
        if self.failed { return Err(FAILED); }
        // Failed until this call completes, so no error path can be forgotten.
        self.failed = true;
        let mut sample = Vec::new();
        if !bytes.is_empty() {
            let packet = self.parameters.prepare(self.codec, bytes)?;
            if packet.changed { self.configured = false; }
            // Parameter sets may arrive separately. Recreate only once the next
            // picture arrives, not with a new SPS paired with the previous PPS.
            if !packet.picture { self.failed = false; return Ok(None); }
            if !self.configured {
                if !self.parameters.complete(self.codec) { return Err(BAD_PACKET); }
                let count = if self.codec == Codec::H264 { 2 } else { 3 };
                let pointers = self.parameters.sets.each_ref().map(|s| s.as_ptr());
                let sizes = self.parameters.sets.each_ref().map(|s| s.len());
                if unsafe { gvi_configure(self.handle.as_ptr(), self.codec as i32, pointers.as_ptr(), sizes.as_ptr(), count) } != 0 {
                    return Err("Hardware VideoToolbox session could not be configured".into());
                }
                self.configured = true;
            }
            sample = packet.sample;
        }
        let (mut pixels, mut width, mut height) = (std::ptr::null(), 0, 0);
        let length = unsafe { gvi_decode(self.handle.as_ptr(), sample.as_ptr(), sample.len(), layout, &mut pixels, &mut width, &mut height) };
        if length < 0 { return Err("Hardware VideoToolbox decoding failed".into()); }
        if length == 0 { self.failed = false; return Ok(None); }
        if pixels.is_null() || width <= 0 || height <= 0 { return Err("Invalid VideoToolbox output".into()); }
        self.failed = false;
        // Native storage remains valid until the next exclusive decoder call.
        Ok(Some((unsafe { std::slice::from_raw_parts(pixels, length as usize) }, width as u32, height as u32)))
    }
}
impl Drop for Decoder {
    fn drop(&mut self) { unsafe { gvi_free(self.handle.as_ptr()) }; }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn annex_b_requires_start_codes_and_bounded_nonempty_nals() {
        assert_eq!(nals(&[0,0,0,1,0x67,9,0,0,1,0x68,8,0,0]).unwrap(), vec![&[0x67,9][..], &[0x68,8][..]]);
        for packet in [vec![], vec![0,0,1], vec![9,0,0,1,0x67], vec![0,0,1,0,0,1,0x67], vec![1; MAX_PACKET+1]] {
            assert!(nals(&packet).is_err());
        }
        assert!(nals(&[0,0,1,0x67].repeat(257)).is_err());
    }
    #[test]
    fn annex_b_accepts_leading_and_trailing_zeros_and_mixed_start_codes() {
        // zero_byte, leading_zero_8bits and trailing_zero_8bits are not NAL data.
        let packet = [0,0,0,0,0,1,0x67,9, 0,0,0,0,0,1,0x68,8, 0,0,1,0x65,7,0xff, 0,0,0];
        assert_eq!(nals(&packet).unwrap(), vec![&[0x67,9][..], &[0x68,8][..], &[0x65,7,0xff][..]]);
        assert_eq!(nals(&[0,0,2,0,0,1,0x67]), Err(BAD_PACKET), "Bytes before the first start code");
        assert_eq!(nals(&[0,0,1,0x67,9,0,0,0,0,1]), Err(BAD_PACKET), "An empty final NAL");
    }
    #[test]
    fn parameter_changes_are_incremental_and_samples_are_length_prefixed() {
        let mut parameters = Parameters::default();
        let header = [0,0,1,0x67,9,0,0,1,0x68,8];
        assert!(parameters.prepare(Codec::H264, &header).unwrap().changed);
        assert!(parameters.complete(Codec::H264));
        assert!(!parameters.prepare(Codec::H264, &header).unwrap().changed);
        let frame = parameters.prepare(Codec::H264, &[0,0,1,0x65,7]).unwrap();
        assert!(frame.picture);
        assert_eq!(frame.sample, [0,0,0,2,0x65,7]);
        assert!(!frame.changed);
        assert!(parameters.prepare(Codec::H264, &[0,0,1,0x67,10]).unwrap().changed);
    }
    #[test]
    fn hevc_needs_all_three_sets_and_valid_temporal_id() {
        let mut parameters = Parameters::default();
        for kind in [32,33,34] {
            let packet = parameters.prepare(Codec::Hevc, &[0,0,1,kind<<1,1,9]).unwrap();
            assert!(packet.changed && !packet.picture);
            assert_eq!(parameters.complete(Codec::Hevc), kind == 34);
        }
        assert!(parameters.prepare(Codec::Hevc, &[0,0,1,38,0]).is_err());
        assert!(parameters.prepare(Codec::H264, &[0,0,1,0xe7,1]).is_err());
    }

    /// The decoder's input contract: parameter sets in separate access units,
    /// then the picture, as a sender that repeats them out of band would send.
    fn split_parameter_sets(codec: Codec, packet: &[u8]) -> Vec<Vec<u8>> {
        let (mut parameters, mut rest) = (Vec::new(), Vec::new());
        for nal in nals(packet).unwrap() {
            let unit = [&[0, 0, 0, 1][..], nal].concat();
            if classify(codec, nal).unwrap().0.is_some() { parameters.push(unit) } else { rest.extend(unit) }
        }
        assert!(!parameters.is_empty() && !rest.is_empty(), "{codec:?} key frame lacks in-band parameters");
        parameters.push(rest);
        parameters
    }
    /// Saturated quadrants: a BT.709 or full-range misreading, a cropped or
    /// shifted plane, or swapped chroma moves these by far more than codec noise.
    const QUADRANTS: [[u8; 3]; 4] = [[220, 40, 40], [40, 200, 40], [40, 60, 220], [230, 220, 40]];
    fn quadrant(x: u32, y: u32, w: u32, h: u32) -> [u8; 3] {
        QUADRANTS[usize::from(y >= h / 2) * 2 + usize::from(x >= w / 2)]
    }
    fn scene(w: u32, h: u32) -> Vec<u8> {
        (0..h).flat_map(|y| (0..w).flat_map(move |x| { let [r, g, b] = quadrant(x, y, w, h); [r, g, b, 255] })).collect()
    }
    /// Quadrant centres and the four extreme pixels, so the last row and column
    /// (where an uncropped or misstrided plane differs first) are always read.
    fn probes(w: u32, h: u32) -> [(u32, u32); 8] {
        [(w/4, h/4), (3*w/4, h/4), (w/4, 3*h/4), (3*w/4, 3*h/4), (0, 0), (w-1, 0), (0, h-1), (w-1, h-1)]
    }
    /// The conversion the Godot client applies to NV12: BT.601 limited range.
    fn nv12_rgb(pixels: &[u8], x: u32, y: u32, w: u32, h: u32) -> [f32; 3] {
        let (w, h, x, y) = (w as usize, h as usize, x as usize, y as usize);
        let luma = (f32::from(pixels[y * w + x]) - 16.0) * 1.164_384;
        let chroma = w * h + (y / 2) * w + (x / 2) * 2;
        let (u, v) = (f32::from(pixels[chroma]) - 128.0, f32::from(pixels[chroma + 1]) - 128.0);
        [luma + 1.596_027 * v, luma - 0.391_762 * u - 0.812_968 * v, luma + 2.017_232 * u].map(|c| c.clamp(0.0, 255.0))
    }
    fn assert_scene(context: &str, pixels: &[u8], layout: i32, w: u32, h: u32) {
        for (x, y) in probes(w, h) {
            let expected = quadrant(x, y, w, h);
            let actual = if layout == crate::RGBA {
                let at = ((y * w + x) * 4) as usize;
                [pixels[at] as f32, pixels[at + 1] as f32, pixels[at + 2] as f32]
            } else { nv12_rgb(pixels, x, y, w, h) };
            for channel in 0..3 {
                assert!((actual[channel] - expected[channel] as f32).abs() < 24.0,
                    "{context} ({x},{y}) {actual:?} != {expected:?}");
            }
        }
    }

    #[test]
    #[ignore = "requires Apple hardware encoder and decoder"]
    fn hardware_roundtrip_and_resolution_change() {
        // The original regression: flat colour, aligned sizes, alternating layouts.
        for codec in [Codec::H264, Codec::Hevc] {
            let mut decoder = Decoder::new(codec, "", 256, 256).unwrap();
            for size in [256, 320] {
                let mut encoder = crate::Encoder::new(codec, size, size).unwrap();
                let rgba = [64, 128, 192, 255].repeat((size * size) as usize);
                for index in 0..8 {
                    let packet = encoder.encode(&rgba, index == 0).unwrap().expect("low-delay packet");
                    let layout = if index % 2 == 0 { crate::NV12 } else { crate::RGBA };
                    let (pixels, w, h) = decoder.frame(&packet.bytes, layout).unwrap().expect("low-delay picture");
                    assert_eq!((w, h), (size, size));
                    assert_eq!(pixels.len(), (size*size) as usize * if layout == crate::NV12 { 3 } else { 8 } / 2);
                    if layout == crate::RGBA {
                        for (actual, expected) in pixels[..4].iter().zip(&rgba[..4]) {
                            assert!(actual.abs_diff(*expected) < 12, "{codec:?}: {:?}", &pixels[..4]);
                        }
                    }
                }
            }
        }
        for codec in [Codec::H264, Codec::Hevc] {
            let mut decoder = Decoder::new(codec, "", 256, 256).unwrap();
            // Aligned, then sizes that need SPS/conformance-window cropping, then back.
            let sizes = [(256, 256), (320, 320), (250, 138), (322, 178), (256, 256)];
            for (step, (w, h)) in sizes.into_iter().enumerate() {
                let mut encoder = crate::Encoder::new(codec, w, h).unwrap();
                let rgba = scene(w, h);
                for index in 0..8 {
                    // The second key frame repeats identical parameter sets: no new session.
                    let packet = encoder.encode(&rgba, index % 4 == 0).unwrap().expect("low-delay packet");
                    let layout = if index % 2 == 0 { crate::NV12 } else { crate::RGBA };
                    let mut units = if index == 0 && step % 2 == 1 {
                        split_parameter_sets(codec, &packet.bytes)
                    } else { vec![packet.bytes] };
                    let picture = units.pop().unwrap();
                    for unit in units {
                        assert!(decoder.frame(&unit, layout).unwrap().is_none(), "{codec:?}: parameter sets alone are not a picture");
                    }
                    let context = format!("{codec:?} {w}x{h} frame {index}");
                    let (pixels, actual_w, actual_h) = decoder.frame(&picture, layout).unwrap().expect("low-delay picture");
                    assert_eq!((actual_w, actual_h), (w, h), "{context}");
                    assert_eq!(pixels.len(), (w * h) as usize * if layout == crate::NV12 { 3 } else { 8 } / 2, "{context}");
                    assert_scene(&context, pixels, layout, w, h);
                }
            }
        }
    }
    #[test]
    #[ignore = "requires Apple hardware encoder and decoder"]
    fn hardware_nv12_matches_rgba() {
        for codec in [Codec::H264, Codec::Hevc] {
            let mut encoder = crate::Encoder::new(codec, 250, 138).unwrap();
            let mut gradient = Vec::new();
            for y in 0..138u32 { for x in 0..250u32 { gradient.extend_from_slice(&[(x * 255 / 249) as u8, (y * 255 / 137) as u8, 90, 255]); } }
            let (mut nv12, mut rgba) = (Decoder::new(codec, "", 0, 0).unwrap(), Decoder::new(codec, "", 0, 0).unwrap());
            for index in 0..4 {
                let packet = encoder.encode(&gradient, index == 0).unwrap().expect("low-delay packet");
                let expected = rgba.frame(&packet.bytes, crate::RGBA).unwrap().expect("picture").0.to_vec();
                let (planes, w, h) = nv12.frame(&packet.bytes, crate::NV12).unwrap().expect("picture");
                assert_eq!((w, h), (250, 138));
                // Same decoded picture, two layouts: every pixel agrees up to rounding.
                for y in 0..h { for x in 0..w {
                    let converted = nv12_rgb(planes, x, y, w, h);
                    for channel in 0..3 {
                        let reference = expected[((y * w + x) * 4) as usize + channel] as f32;
                        assert!((converted[channel] - reference).abs() < 3.0, "{codec:?} ({x},{y}) {converted:?} vs {reference}");
                    }
                } }
            }
        }
    }
    #[test]
    #[ignore = "requires Apple hardware encoder and decoder"]
    fn hardware_failure_is_terminal() {
        for codec in [Codec::H264, Codec::Hevc] {
            let mut encoder = crate::Encoder::new(codec, 256, 256).unwrap();
            let rgba = scene(256, 256);
            let key = encoder.encode(&rgba, true).unwrap().unwrap().bytes;
            let delta = encoder.encode(&rgba, false).unwrap().unwrap().bytes;
            // A picture without parameter sets cannot start a stream.
            let slice: &[u8] = if codec == Codec::H264 { &[0, 0, 1, 0x41, 0x9a, 1] } else { &[0, 0, 1, 2, 1, 1] };
            let mut decoder = Decoder::new(codec, "", 0, 0).unwrap();
            assert!(decoder.frame(slice, crate::RGBA).is_err());
            // Dropping that picture would corrupt references: even a key frame is refused.
            assert_eq!(decoder.frame(&key, crate::RGBA).err(), Some(FAILED));
            // A malformed access unit mid-stream is terminal as well.
            let mut decoder = Decoder::new(codec, "", 0, 0).unwrap();
            assert!(decoder.frame(&key, crate::NV12).unwrap().is_some());
            assert!(decoder.frame(&[0, 0, 1, 0x80], crate::NV12).is_err());
            assert_eq!(decoder.frame(&delta, crate::NV12).err(), Some(FAILED));
            assert_eq!(decoder.frame(&[], crate::NV12).err(), Some(FAILED));
        }
    }
    #[test]
    #[ignore = "requires Apple hardware encoder and decoder"]
    fn hardware_corrupt_input_is_contained() {
        let mut seed = 0x1234_5678_u64;
        let mut next = move || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; seed };
        for codec in [Codec::H264, Codec::Hevc] {
            let mut encoder = crate::Encoder::new(codec, 250, 138).unwrap();
            let rgba = scene(250, 138);
            let key = encoder.encode(&rgba, true).unwrap().unwrap().bytes;
            let delta = encoder.encode(&rgba, false).unwrap().unwrap().bytes;
            let (mut accepted, mut rejected) = (0, 0);
            for case in 0..120 {
                let mut corrupt = key.clone();
                match case % 4 {
                    0 => { let keep = 1 + next() as usize % corrupt.len(); corrupt.truncate(keep); }
                    1 => for _ in 0..4 { let at = next() as usize % corrupt.len(); corrupt[at] ^= 1 << (next() % 8); },
                    2 => for _ in 0..40 { let at = 20 + next() as usize % (corrupt.len() - 20); corrupt[at] = next() as u8; },
                    _ => { let at = next() as usize % corrupt.len().min(120); corrupt[at] ^= 0xff; }
                }
                let mut decoder = Decoder::new(codec, "", 0, 0).unwrap();
                match decoder.frame(&corrupt, crate::RGBA) {
                    Ok(Some((pixels, w, h))) => {
                        // Damaged pictures (even a damaged SPS that changes the size) may be
                        // accepted; the buffer must still match the reported size.
                        assert!((1..=8192).contains(&w) && (1..=8192).contains(&h));
                        assert_eq!(pixels.len(), (w * h * 4) as usize);
                        accepted += 1;
                        let _ = decoder.frame(&delta, crate::NV12);
                    }
                    Ok(None) => accepted += 1,
                    Err(_) => {
                        rejected += 1;
                        assert_eq!(decoder.frame(&key, crate::RGBA).err(), Some(FAILED));
                    }
                }
            }
            assert!(rejected > 0, "{codec:?}: corruption was never detected ({accepted} accepted)");
        }
    }
}
