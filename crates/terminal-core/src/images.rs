//! Image pixels and placements are owned by the authoritative VT, just like cells.
//! Snapshots re-emit images at their retained scrollback rows, not an output log.
use crate::Error;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use libghostty_vt::{Terminal, kitty::graphics as kg, terminal::PointSpace};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet, VecDeque},
    io::Cursor,
    sync::Arc,
};

pub const CELL: (u32, u32) = (12, 23);
pub const STORAGE: u64 = 320_000_000;

/// Image policy belongs to the terminal's owner, independently of its renderer.
/// Cell dimensions are explicit because the server and graphical frontends use
/// different geometry. Constructors deliberately do not choose terminal limits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Policy {
    pub limits: crate::limits::TerminalLimits,
    pub cell: (u32, u32),
    external_uploads: bool,
}

impl Policy {
    /// An authoritative terminal may resolve images on its own host.
    pub fn owner(limits: crate::limits::TerminalLimits, cell: (u32, u32)) -> Self {
        Self {
            limits,
            cell,
            external_uploads: true,
        }
    }

    /// A mirror receives inline image data and never opens a peer's file or SHM.
    pub fn mirror(limits: crate::limits::TerminalLimits, cell: (u32, u32)) -> Self {
        Self {
            limits,
            cell,
            external_uploads: false,
        }
    }

    pub fn allows_external_uploads(self) -> bool {
        self.external_uploads
    }

    /// Install the shared decoder and configure this terminal's image geometry.
    /// The decoder is process-wide; this does not install VT reply callbacks.
    pub fn configure(self, vt: &mut Terminal<'_, '_>) -> Result<(), Error> {
        if self.cell.0 == 0 || self.cell.1 == 0 {
            return Err("Terminal image cell dimensions must be nonzero".into());
        }
        // SAFETY: libghostty stores one process-wide hook pointer without a
        // lock.
        //
        // Every install writes the same trampoline; the Rust side swaps the
        // boxed decoder under its own mutex, so parsing threads never see a
        // dangling decoder.
        unsafe { kg::set_png_decoder(Some(Box::new(PngDecoder))) }?;
        self.apply(vt)?;
        vt.resize(vt.cols()?, vt.rows()?, self.cell.0, self.cell.1)?;
        Ok(())
    }

    /// Reapply at the RIS boundary before feeding subsequent bytes. Ghostty's
    /// reset recreates image storage, so policy must be restored in stream order.
    pub fn apply(self, vt: &mut Terminal<'_, '_>) -> Result<(), Error> {
        apply_policy(vt, self.limits, self.external_uploads)
    }
}

pub fn configure(vt: &mut Terminal<'_, '_>) -> Result<(), Error> {
    configure_with_limits(vt, Default::default())
}
pub fn configure_with_limits(
    vt: &mut Terminal<'_, '_>,
    limits: crate::limits::TerminalLimits,
) -> Result<(), Error> {
    Policy::owner(limits, CELL).configure(vt)
}

/// RIS recreates Ghostty's image storage with default limits. Restore the host
/// policy at that exact stream boundary, before any following upload is parsed.
/// Mirrors must also retain their prohibition on opening peer-supplied paths.
pub fn apply_policy(
    vt: &mut Terminal<'_, '_>,
    limits: crate::limits::TerminalLimits,
    external_uploads: bool,
) -> Result<(), Error> {
    limits.validate().map_err(std::io::Error::other)?;
    vt.set_kitty_image_storage_limit(limits.storage_bytes())?;
    vt.set_kitty_image_from_file_allowed(external_uploads)?;
    // Ghostty now confines the temporary-file medium to one directory. Kitty
    // clients (including `gft terminal icat`) create those files in the OS temp dir.
    let temp_dir = std::env::temp_dir();
    vt.set_kitty_image_temp_file_dir(external_uploads.then_some(temp_dir.as_path()))?;
    vt.set_kitty_image_from_shared_mem_allowed(external_uploads)?;
    vt.set_apc_max_bytes(Some(limits.transmission_bytes()))?;
    vt.set_apc_max_bytes_kitty(Some(limits.transmission_bytes()))?;
    Ok(())
}
const DECODE_CACHE_BYTES: usize = 64 * 1024 * 1024;
#[derive(Default)]
struct DecodeCache {
    entries: VecDeque<(blake3::Hash, Arc<image::RgbaImage>)>,
    bytes: usize,
    decodes: u64,
}
thread_local! { static DECODE_CACHE: RefCell<DecodeCache> = RefCell::default(); }
#[derive(Clone)]
struct SourcePng {
    pixels: Arc<image::RgbaImage>,
    bytes: Arc<[u8]>,
}
struct OriginalPng {
    generation: u64,
    bytes: Arc<[u8]>,
}
// A decode callback receives the PNG even for file/temp-file/shared-memory
// uploads. Capture it while the owning session feeds its VT; never reopen the
// application's file later. Only the session actor installs this capture scope.
thread_local! { static RECEIVED_PNGS: RefCell<Option<Vec<SourcePng>>> = const { RefCell::new(None) }; }
// The server actor owns all VTs on this thread, so this cache is shared across
// terminals and clients, without locks or running the decoder concurrently.
fn decode(data: &[u8]) -> Option<Arc<image::RgbaImage>> {
    let key = blake3::hash(data);
    if let Some(image) = DECODE_CACHE.with_borrow_mut(|cache| {
        let at = cache.entries.iter().position(|(hash, _)| *hash == key)?;
        let entry = cache.entries.remove(at)?;
        let image = entry.1.clone();
        cache.entries.push_back(entry);
        Some(image)
    }) {
        return Some(image);
    }
    let image = Arc::new(decode_uncached(data)?);
    DECODE_CACHE.with_borrow_mut(|cache| {
        cache.decodes += 1;
        while cache.bytes + image.len() > DECODE_CACHE_BYTES || cache.entries.len() >= 1024 {
            let Some((_, old)) = cache.entries.pop_front() else {
                break;
            };
            cache.bytes -= old.len();
        }
        if image.len() <= DECODE_CACHE_BYTES {
            cache.bytes += image.len();
            cache.entries.push_back((key, image.clone()));
        }
    });
    Some(image)
}
fn decode_uncached(data: &[u8]) -> Option<image::RgbaImage> {
    let mut reader = image::ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .ok()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    Some(reader.decode().ok()?.into_rgba8())
}
pub fn inline_decode(data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let image = decode(data)?;
    let (w, h) = image.dimensions();
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some((data.to_vec(), w, h));
    }
    let mut bytes = Cursor::new(Vec::new());
    image.write_to(&mut bytes, image::ImageFormat::Png).ok()?;
    Some((bytes.into_inner(), w, h))
}
struct PngDecoder;
impl kg::DecodePng for PngDecoder {
    fn decode_png<'a>(
        &mut self,
        alloc: &'a libghostty_vt::alloc::Allocator<'_>,
        data: &[u8],
    ) -> Option<kg::DecodedImage<'a>> {
        let image = decode(data)?;
        RECEIVED_PNGS.with_borrow_mut(|pending| {
            if let Some(pending) = pending {
                if data.starts_with(b"\x89PNG\r\n\x1a\n")
                    && data.len() <= DECODE_CACHE_BYTES
                    && pending.iter().map(|png| png.bytes.len()).sum::<usize>() + data.len()
                        <= STORAGE as usize
                {
                    pending.push(SourcePng {
                        pixels: image.clone(),
                        bytes: Arc::from(data),
                    });
                }
            }
        });
        let mut bytes = libghostty_vt::alloc::Bytes::new_zeroed_with_alloc(alloc, image.len()).ok()?;
        bytes.copy_from_slice(image.as_raw());
        Some(kg::DecodedImage {
            width: image.width(),
            height: image.height(),
            data: bytes,
        })
    }
}

pub struct State {
    storage_bytes: usize,
    // Explicit IDs also cover transmitted images which have not been placed yet.
    ids: [BTreeSet<u32>; 2],
    numbers: [BTreeSet<u32>; 2],
    originals: [BTreeMap<u32, OriginalPng>; 2],
    received_pngs: Vec<SourcePng>,
    pending: Pending,
    pub external_upload: bool,
    pub inline: crate::inline_images::Images,
}
impl Default for State {
    fn default() -> Self {
        Self::with_limit(STORAGE)
    }
}
impl State {
    pub fn original(&self, vt: &Terminal<'_, '_>, id: u32, generation: u64) -> Option<Arc<[u8]>> {
        let screen = usize::from(vt.active_screen().ok() == Some(libghostty_vt::screen::Screen::Alternate));
        self.originals[screen].get(&id).filter(|p| p.generation == generation).map(|p| p.bytes.clone())
    }
    pub fn with_limits(limits: crate::limits::TerminalLimits) -> Self {
        let mut state = Self::with_limit(limits.storage_bytes());
        state.pending.kitty_bytes = limits.transmission_bytes();
        state
    }
    pub fn with_limit(storage_bytes: u64) -> Self {
        Self {
            storage_bytes: storage_bytes as usize,
            ids: Default::default(),
            numbers: Default::default(),
            originals: Default::default(),
            received_pngs: vec![],
            pending: Default::default(),
            external_upload: false,
            inline: Default::default(),
        }
    }
    pub fn stream_ready(&self) -> bool {
        !self.external_upload || self.transaction_complete()
    }
    /// Pixel-only streams cannot forward a partial image transaction before the
    /// owner has decoded it. This also holds an ambiguous partial ESC prefix.
    pub fn transaction_complete(&self) -> bool {
        self.pending.bytes.is_empty() && self.pending.multipart.is_empty()
    }
    pub fn feed(&mut self, bytes: &[u8]) {
        RECEIVED_PNGS.with_borrow_mut(|pending| *pending = Some(Vec::new()));
        self.pending.feed(bytes);
    }
    pub fn reset(&mut self) {
        self.ids = Default::default();
        self.numbers = Default::default();
        self.originals = Default::default();
        self.received_pngs.clear();
        RECEIVED_PNGS.with_borrow_mut(|pending| {
            if let Some(pending) = pending {
                pending.clear();
            }
        });
        self.inline = Default::default();
    }
    pub fn header(&mut self, header: &str, vt: &Terminal<'_, '_>) {
        let screen =
            usize::from(vt.active_screen().ok() == Some(libghostty_vt::screen::Screen::Alternate));
        // Numbered/anonymous uploads allocate IDs inside Ghostty. Canonical
        // snapshots carry the server-assigned IDs; independent clients must
        // never allocate a conflicting ID or reinterpret a server image number.
        if !header.split(',').any(|pair| {
            pair.strip_prefix("i=")
                .and_then(|v| v.parse::<u32>().ok())
                .is_some_and(|id| id != 0)
        }) || header
            .split(',')
            .any(|pair| pair.starts_with("I=") && pair != "I=0")
        {
            self.external_upload = true;
        }
        for pair in header.split(',') {
            if matches!(pair, "t=f" | "t=t" | "t=s") {
                self.external_upload = true;
            }
            if let Some(id) = pair.strip_prefix("i=").and_then(|v| v.parse().ok()) {
                self.ids[screen].insert(id);
            }
            if let Some(number) = pair.strip_prefix("I=").and_then(|v| v.parse().ok()) {
                self.numbers[screen].insert(number);
            }
        }
    }
    pub fn prune(&mut self, vt: &mut Terminal<'_, '_>) {
        if let Some(pngs) = RECEIVED_PNGS.with_borrow_mut(Option::take) {
            self.received_pngs.extend(pngs);
        }
        let mut received_bytes: usize = self.received_pngs.iter().map(|png| png.bytes.len()).sum();
        while received_bytes > self.storage_bytes {
            let Some(png) = self.received_pngs.pop() else {
                break;
            };
            received_bytes -= png.bytes.len();
        }
        let screen =
            usize::from(vt.active_screen().ok() == Some(libghostty_vt::screen::Screen::Alternate));
        if !self.pending.bytes.is_empty() || !self.pending.multipart.is_empty() {
            return;
        }
        for number in std::mem::take(&mut self.numbers[screen]) {
            if number == 0 {
                continue;
            }
            if let Ok(Some(id)) = resolve_number(vt, number) {
                self.ids[screen].insert(id);
            }
        }
        if let Ok(Some(graphics)) = vt.kitty_graphics() {
            // Anonymous uploads acquire their IDs inside Ghostty. Include the
            // placed IDs so their original PNG survives attach/reconnect too.
            if let Ok(mut iterator) = kg::PlacementIterator::new() {
                if let Ok(mut placements) = iterator.update(&graphics) {
                    while let Some(placement) = placements.next() {
                        if let Ok(id) = placement.image_id() {
                            self.ids[screen].insert(id);
                        }
                    }
                }
            }
            self.ids[screen].retain(|id| graphics.image(*id).is_some());
            self.originals[screen].retain(|id, _| self.ids[screen].contains(id));
            for id in &self.ids[screen] {
                let Some(image) = graphics.image(*id) else {
                    continue;
                };
                let Ok(generation) = image.generation() else {
                    continue;
                };
                if self.originals[screen]
                    .get(id)
                    .is_some_and(|original| original.generation == generation)
                {
                    continue;
                }
                if self.received_pngs.is_empty() {
                    if self.originals[screen]
                        .get(id)
                        .is_some_and(|original| original.generation != generation)
                    {
                        self.originals[screen].remove(id);
                    }
                    continue;
                }
                let Ok(Some(raw)) = image.data() else {
                    continue;
                };
                let matching = self.received_pngs.iter().rev().find(|png| {
                    image.width().ok() == Some(png.pixels.width())
                        && image.height().ok() == Some(png.pixels.height())
                        && raw == png.pixels.as_raw()
                });
                if let Some(png) = matching {
                    self.originals[screen].insert(
                        *id,
                        OriginalPng {
                            generation,
                            bytes: png.bytes.clone(),
                        },
                    );
                } else {
                    self.originals[screen].remove(id);
                }
            }
        }
        self.received_pngs.clear();
        // Encoded assets have their own finite budget, in addition to Ghostty's
        // decoded-pixel budget. Evicted originals fall back to raw pixel bytes,
        // never PNG re-encoding. Existing snapshots own their Arc independently.
        let mut retained: usize = self
            .originals
            .iter()
            .flat_map(|screen| screen.values())
            .map(|png| png.bytes.len())
            .sum();
        for screen in &mut self.originals {
            while retained > self.storage_bytes {
                let Some((_, original)) = screen.pop_first() else {
                    break;
                };
                retained -= original.bytes.len();
            }
        }
    }
    pub fn capture(&self, vt: &Terminal<'_, '_>, text: Vec<u8>) -> Result<Vec<u8>, Error> {
        self.capture_for_transport(vt, text, false)
    }
    /// Local byte IPC uses the owner's already-decoded pixels. Remote replay
    /// retains original PNG bytes; neither path re-encodes an image.
    pub fn capture_rgba(&self, vt: &Terminal<'_, '_>, text: Vec<u8>) -> Result<Vec<u8>, Error> {
        if !self.transaction_complete() {
            return Err("Pixel replay requires a complete image transaction".into());
        }
        self.capture_for_transport(vt, text, true)
    }
    fn capture_for_transport(
        &self,
        vt: &Terminal<'_, '_>,
        text: Vec<u8>,
        rgba: bool,
    ) -> Result<Vec<u8>, Error> {
        let screen =
            usize::from(vt.active_screen().ok() == Some(libghostty_vt::screen::Screen::Alternate));
        let mut bytes =
            snapshot_originals(vt, text, &self.ids[screen], &self.originals[screen], rgba)?;
        bytes.extend_from_slice(&self.pending.multipart);
        bytes.extend_from_slice(&self.pending.bytes);
        Ok(bytes)
    }
}

// The inspection API only looks up image IDs. Resolve numbered, unplaced
// uploads with a temporary virtual placement, which never paints or moves the
// cursor. Removing that placement leaves the pixels and their allocated ID.
fn resolve_number(vt: &mut Terminal<'_, '_>, number: u32) -> Result<Option<u32>, Error> {
    let mut used = BTreeSet::new();
    {
        let Some(graphics) = vt.kitty_graphics()? else { return Ok(None) };
        let mut iter = kg::PlacementIterator::new()?;
        let mut placements = iter.update(&graphics)?;
        while let Some(p) = placements.next() {
            used.insert(p.placement_id()?);
        }
    }
    let placement = (1..=u32::MAX)
        .rev()
        .find(|id| !used.contains(id))
        .ok_or("No free image placement ID")?;
    vt.vt_write(format!("\x1b_Ga=p,I={number},p={placement},U=1,c=1,r=1,C=1,q=2\x1b\\").as_bytes());
    let mut found = None;
    {
        let Some(graphics) = vt.kitty_graphics()? else { return Ok(None) };
        let mut iter = kg::PlacementIterator::new()?;
        let mut placements = iter.update(&graphics)?;
        while let Some(p) = placements.next() {
            if p.placement_id()? == placement {
                found = Some(p.image_id()?);
                break;
            }
        }
    }
    if let Some(id) = found {
        vt.vt_write(format!("\x1b_Ga=d,d=i,i={id},p={placement},q=2\x1b\\").as_bytes());
    }
    Ok(found)
}

fn command(out: &mut Vec<u8>, header: &str) {
    out.extend_from_slice(format!("\x1b_G{header}\x1b\\").as_bytes());
}
fn transmit(
    out: &mut Vec<u8>,
    image: &kg::Image<'_>,
    original: Option<&OriginalPng>,
    rgba: bool,
) -> Result<(), Error> {
    let original_format = image.format()?;
    let raw = image.data()?.ok_or("Owner image has no pixels")?;
    let converted;
    let (format, compression, pixels) = if rgba {
        if image.compression()? != kg::Compression::None {
            return Err("Owner image pixels remain compressed".into());
        }
        let channels = match original_format {
            kg::ImageFormat::Rgba => 4,
            kg::ImageFormat::Rgb => 3,
            kg::ImageFormat::GrayAlpha => 2,
            kg::ImageFormat::Gray => 1,
            _ => return Err("Owner image pixels are not decoded".into()),
        };
        if raw.len() != image.width()? as usize * image.height()? as usize * channels {
            return Err("Owner image pixel dimensions do not match storage".into());
        }
        let pixels = if channels == 4 {
            raw
        } else {
            converted = raw
                .chunks_exact(channels)
                .flat_map(|p| match channels {
                    3 => [p[0], p[1], p[2], 255],
                    2 => [p[0], p[0], p[0], p[1]],
                    _ => [p[0], p[0], p[0], 255],
                })
                .collect::<Vec<_>>();
            &converted
        };
        (32, "", pixels)
    } else if let Some(original) =
        original.filter(|png| image.generation().ok() == Some(png.generation))
    {
        (100, "", original.bytes.as_ref())
    } else {
        let format = match original_format {
            kg::ImageFormat::Rgb => 24,
            kg::ImageFormat::Rgba => 32,
            kg::ImageFormat::Png => 100,
            _ => return Err("Unsupported compressed image format".into()),
        };
        (
            format,
            if image.compression()? == kg::Compression::ZlibDeflate {
                ",o=z"
            } else {
                ""
            },
            raw,
        )
    };
    let payload = B64.encode(pixels);
    for (index, chunk) in payload.as_bytes().chunks(4096).enumerate() {
        let more = usize::from((index + 1) * 4096 < payload.len());
        let header = if index == 0 {
            format!(
                "a=t,t=d,f={format},s={},v={},i={},q=2,m={more}{compression}",
                image.width()?,
                image.height()?,
                image.id()?
            )
        } else {
            format!("m={more},q=2")
        };
        out.extend_from_slice(format!("\x1b_G{header};").as_bytes());
        out.extend_from_slice(chunk);
        out.extend_from_slice(b"\x1b\\");
    }
    Ok(())
}

#[cfg(test)]
pub fn snapshot(
    vt: &Terminal<'_, '_>,
    text: Vec<u8>,
    known: &BTreeSet<u32>,
) -> Result<Vec<u8>, Error> {
    snapshot_originals(vt, text, known, &BTreeMap::new(), false)
}

fn snapshot_originals(
    vt: &Terminal<'_, '_>,
    text: Vec<u8>,
    known: &BTreeSet<u32>,
    originals: &BTreeMap<u32, OriginalPng>,
    rgba: bool,
) -> Result<Vec<u8>, Error> {
    // The formatter repeats alternate-screen entry after palette setup. Reentry
    // clears its images, so retain only the explicit entry in our prefix.
    let text = if text.starts_with(b"\x1bc\x1b[?1049h") {
        let prefix = b"\x1bc\x1b[?1049h";
        let mut cleaned = prefix.to_vec();
        let tail = &text[prefix.len()..];
        let mut at = 0;
        while at < tail.len() {
            if tail[at..].starts_with(b"\x1b[?1049h") {
                at += 8;
            } else {
                cleaned.push(tail[at]);
                at += 1;
            }
        }
        cleaned
    } else {
        text
    };
    let Some(graphics) = vt.kitty_graphics()? else { return Ok(text) };
    let mut iterator = kg::PlacementIterator::new()?;
    let mut placements = iterator.update(&graphics)?;
    let mut ids = known.clone();
    let mut rows: BTreeMap<usize, Vec<(u16, String)>> = BTreeMap::new();
    let mut virtuals = Vec::new();
    while let Some(p) = placements.next() {
        let id = p.image_id()?;
        let Some(image) = graphics.image(id) else {
            continue;
        };
        ids.insert(id);
        let header = format!(
            "a=p,i={id},p={},q=2,C=1,U={},c={},r={},x={},y={},w={},h={},X={},Y={},z={}",
            p.placement_id()?,
            u8::from(p.is_virtual()?),
            p.columns()?,
            p.rows()?,
            p.source_x()?,
            p.source_y()?,
            p.source_width()?,
            p.source_height()?,
            p.x_offset()?,
            p.y_offset()?,
            p.z()?
        );
        if p.is_virtual()? {
            virtuals.push(header);
            continue;
        }
        let Some(rect) = p.rect(&image, vt)? else { continue };
        if let Some(point) = vt.point_from_grid_ref(&rect.start(), PointSpace::Screen)? {
            rows.entry(point.y as usize)
                .or_default()
                .push((point.x, header));
        }
    }
    if ids.is_empty() {
        return Ok(text);
    }
    // The first reset (and alternate-screen entry) must precede image uploads.
    let prefix = if text.starts_with(b"\x1bc\x1b[?1049h") {
        b"\x1bc\x1b[?1049h".len()
    } else {
        2
    };
    let mut out = text[..prefix].to_vec();
    for id in ids {
        if let Some(image) = graphics.image(id) {
            transmit(&mut out, &image, originals.get(&id), rgba)?;
        }
    }
    for header in virtuals {
        command(&mut out, &header);
    }
    let mut probe = crate::new_vt(vt.cols()?, vt.rows()?, 10000)?;
    probe.vt_write(&text[..prefix]);
    insert_rows(&probe, &mut rows, &mut out)?;
    // Only probe until the last placement is installed. At a new retained
    // row, suspend replay between complete VT tokens, save/restore the cursor
    // (also its pending-wrap flag), and place without moving it.
    //
    // Future text/scrolling then carries the same image pins as the source
    // terminal.
    let mut parser = Boundary::default();
    for (index, byte) in text[prefix..].iter().enumerate() {
        out.push(*byte);
        probe.vt_write(&[*byte]);
        if parser.feed(*byte) {
            insert_rows(&probe, &mut rows, &mut out)?;
        }
        if rows.is_empty() {
            out.extend_from_slice(&text[prefix + index + 1..]);
            break;
        }
    }
    if !rows.is_empty() {
        return Err("Image placement outside checkpoint rows".into());
    }
    Ok(out)
}
fn insert_rows(
    vt: &Terminal<'_, '_>,
    rows: &mut BTreeMap<usize, Vec<(u16, String)>>,
    out: &mut Vec<u8>,
) -> Result<(), Error> {
    let bottom = vt.total_rows()?;
    let top = bottom.saturating_sub(usize::from(vt.rows()?));
    while rows.first_key_value().is_some_and(|(row, _)| *row < bottom) {
        let (row, placements) = rows.pop_first().unwrap();
        if row < top {
            return Err("Image row passed during checkpoint".into());
        }
        out.extend_from_slice(b"\x1b7");
        for (column, header) in placements {
            out.extend_from_slice(format!("\x1b[{};{}H", row - top + 1, column + 1).as_bytes());
            command(out, &header);
        }
        out.extend_from_slice(b"\x1b8");
    }
    Ok(())
}

// Save only unfinished parser and image transactions. On attach or
// reconnect, seed the decoder with that state before the next live chunk
// so an upload can finish.
struct Pending {
    parser: Boundary,
    bytes: Vec<u8>,
    multipart: Vec<u8>,
    kitty_bytes: usize,
}
impl Default for Pending {
    fn default() -> Self {
        Self {
            parser: Default::default(),
            bytes: vec![],
            multipart: vec![],
            kitty_bytes: 48 * 1024 * 1024,
        }
    }
}
impl Pending {
    fn feed(&mut self, bytes: &[u8]) {
        for &b in bytes {
            let was_pending = self.parser.mode != 0 || self.parser.utf8 != 0;
            // Ghostty dispatches strings on ESC, before the final ST backslash.
            let string_end = self.parser.mode == 3 && b == 0x1b;
            let complete = self.parser.feed(b) || string_end;
            if was_pending || !complete {
                let limit = if self.bytes.starts_with(b"\x1b_G") {
                    self.kitty_bytes
                } else {
                    48 * 1024 * 1024
                };
                if self.bytes.len() < limit {
                    self.bytes.push(b);
                }
                if complete {
                    if string_end {
                        self.bytes.push(b'\\');
                    }
                    if self.bytes.starts_with(b"\x1b_G") {
                        let header = self.bytes[3..]
                            .split(|b| *b == b';' || *b == 0x1b)
                            .next()
                            .unwrap_or_default();
                        let more = header.split(|b| *b == b',').any(|v| v == b"m=1");
                        if more && self.multipart.len() + self.bytes.len() <= self.kitty_bytes {
                            self.multipart.extend_from_slice(&self.bytes);
                        } else {
                            self.multipart.clear();
                        }
                    } else if self.bytes.starts_with(b"\x1b]1337;MultipartFile=") {
                        self.multipart = self.bytes.clone();
                    } else if self.bytes.starts_with(b"\x1b]1337;FilePart=") {
                        if self.multipart.len() + self.bytes.len() <= 48 * 1024 * 1024 {
                            self.multipart.extend_from_slice(&self.bytes);
                        }
                    } else if self.bytes.starts_with(b"\x1b]1337;FileEnd") || self.bytes == b"\x1bc"
                    {
                        self.multipart.clear();
                    }
                    self.bytes.clear();
                    if string_end {
                        self.bytes.push(0x1b);
                        self.parser.mode = 1;
                    }
                }
            }
        }
    }
}

#[derive(Default)]
struct Boundary {
    mode: u8,
    utf8: u8,
}
impl Boundary {
    fn feed(&mut self, b: u8) -> bool {
        if self.utf8 > 0 {
            self.utf8 -= 1;
            return self.utf8 == 0;
        }
        self.mode = match self.mode {
            0 => match b {
                0x1b => 1,
                0xc0..=0xdf => {
                    self.utf8 = 1;
                    0
                }
                0xe0..=0xef => {
                    self.utf8 = 2;
                    0
                }
                0xf0..=0xf7 => {
                    self.utf8 = 3;
                    0
                }
                _ => 0,
            },
            1 => match b {
                b'[' => 2,
                b']' | b'_' | b'P' | b'^' | b'X' => 3,
                0x20..=0x2f => 1,
                _ => 0,
            },
            2 => {
                if (0x40..=0x7e).contains(&b) {
                    0
                } else {
                    2
                }
            }
            3 => {
                if b == 0x1b {
                    4
                } else if b == 7 {
                    0
                } else {
                    3
                }
            }
            _ => {
                if b == b'\\' {
                    0
                } else {
                    3
                }
            }
        };
        self.mode == 0 && self.utf8 == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn terminal() -> Terminal<'static, 'static> {
        let mut vt = crate::new_vt(20, 5, 100).unwrap();
        configure(&mut vt).unwrap();
        vt
    }
    #[test]
    fn original_png_survives_file_removal_and_reconnect_without_reencoding() {
        let png = B64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==").unwrap();
        assert_eq!(inline_decode(&png).unwrap().0, png);
        for medium in ["d", "f", "t"] {
            let path = std::env::temp_dir().join(format!(
                "tty-graphics-protocol-{}.png",
                uuid::Uuid::new_v4()
            ));
            std::fs::write(&path, &png).unwrap();
            let payload = if medium == "d" {
                B64.encode(&png)
            } else {
                B64.encode(path.to_string_lossy().as_bytes())
            };
            let header = format!("a=T,t={medium},f=100,i=91,p=1,c=2,r=2,q=2");
            let bytes = format!("\x1b_G{header};{payload}\x1b\\");
            let mut source = terminal();
            let mut state = State::default();
            state.feed(bytes.as_bytes());
            state.header(&header, &source);
            source.vt_write(bytes.as_bytes());
            state.prune(&mut source);
            assert_eq!(state.originals[0][&91].bytes.as_ref(), png);
            let _ = std::fs::remove_file(&path);
            for _ in 0..2 {
                let checkpoint = state
                    .capture(&source, crate::checkpoint::capture(&source).unwrap())
                    .unwrap();
                assert!(
                    String::from_utf8_lossy(&checkpoint).contains(&B64.encode(&png)),
                    "Original PNG bytes must be transmitted verbatim"
                );
                let mut client = terminal();
                client.vt_write(&checkpoint);
                assert_eq!(placement_state(&source), placement_state(&client));
            }
            // Reusing an ID for raw pixels must never resurrect the old PNG.
            let bytes = b"\x1b_Ga=T,f=32,s=1,v=1,i=91,p=1,c=2,r=2,q=2;AP8A/w==\x1b\\";
            state.feed(bytes);
            state.header("a=T,f=32,i=91", &source);
            source.vt_write(bytes);
            state.prune(&mut source);
            let checkpoint = state
                .capture(&source, crate::checkpoint::capture(&source).unwrap())
                .unwrap();
            let mut client = terminal();
            client.vt_write(&checkpoint);
            assert_eq!(placement_state(&source), placement_state(&client));
            assert!(!String::from_utf8_lossy(&checkpoint).contains(&B64.encode(&png)));
        }
    }
    #[test]
    fn local_pixel_replay_needs_no_png_decoder_while_remote_preserves_source() {
        let png = B64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==").unwrap();
        let mut source = terminal();
        let mut state = State::default();
        let header = "a=T,f=100,i=91,p=1,c=2,r=2,q=2";
        let bytes = format!("\x1b_G{header};{}\x1b\\", B64.encode(&png));
        state.feed(bytes.as_bytes());
        state.header(header, &source);
        source.vt_write(bytes.as_bytes());
        state.prune(&mut source);
        let raw = state
            .capture_rgba(&source, crate::checkpoint::capture(&source).unwrap())
            .unwrap();
        assert!(String::from_utf8_lossy(&raw).contains("f=32"));
        assert!(!String::from_utf8_lossy(&raw).contains("f=100"));
        let mut mirror = terminal();
        struct NoDecode(std::sync::Arc<std::sync::atomic::AtomicUsize>);
        impl kg::DecodePng for NoDecode {
            fn decode_png<'a>(
                &mut self,
                _alloc: &'a libghostty_vt::alloc::Allocator<'_>,
                _data: &[u8],
            ) -> Option<kg::DecodedImage<'a>> {
                self.0.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                None
            }
        }
        let decoded = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        // Keep the global C trampoline installed; only this test thread's
        // decoder is disabled, so concurrent remote-PNG tests remain valid.
        unsafe { kg::set_png_decoder(Some(Box::new(NoDecode(decoded.clone())))) }.unwrap();
        mirror.vt_write(&raw);
        assert_eq!(decoded.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(placement_state(&source), placement_state(&mirror));
        // The independent remote cache keeps the exact original encoded bytes.
        let remote = state
            .capture(&source, crate::checkpoint::capture(&source).unwrap())
            .unwrap();
        assert!(String::from_utf8_lossy(&remote).contains(&B64.encode(&png)));
        configure(&mut mirror).unwrap();
    }

    fn image(vt: &mut Terminal<'_, '_>, id: u32, place: bool) {
        vt.vt_write(
            format!(
                "\x1b_Ga={},f=32,s=2,v=1,i={id},p=7,c=3,r=2,z=-2,X=1,Y=2,q=2;{}\x1b\\",
                if place { "T" } else { "t" },
                B64.encode([255, 0, 0, 255, 0, 255, 0, 255])
            )
            .as_bytes(),
        );
    }
    fn placement_state(vt: &Terminal<'_, '_>) -> Vec<String> {
        let graphics = vt.kitty_graphics().unwrap().unwrap();
        let mut iter = kg::PlacementIterator::new().unwrap();
        let mut placements = iter.update(&graphics).unwrap();
        let mut result = Vec::new();
        while let Some(p) = placements.next() {
            let image = graphics.image(p.image_id().unwrap()).unwrap();
            let position = if p.is_virtual().unwrap() {
                None
            } else {
                vt.point_from_grid_ref(&p.rect(&image, vt).unwrap().unwrap().start(), PointSpace::Screen)
                    .unwrap()
            };
            result.push(format!(
                "{}:{}:{position:?}:{}:{}:{}:{}:{}:{:?}",
                p.image_id().unwrap(),
                p.placement_id().unwrap(),
                p.columns().unwrap(),
                p.rows().unwrap(),
                p.x_offset().unwrap(),
                p.y_offset().unwrap(),
                p.z().unwrap(),
                image.data().unwrap()
            ));
        }
        result.sort();
        result
    }
    fn roundtrip(source: &Terminal<'_, '_>, ids: &BTreeSet<u32>) -> Terminal<'static, 'static> {
        let snapshot = snapshot(source, crate::checkpoint::capture(source).unwrap(), ids).unwrap();
        let mut client = terminal();
        // The network may split any escape sequence or image chunk.
        for chunk in snapshot.chunks(37) {
            client.vt_write(chunk);
        }
        assert_eq!(
            placement_state(source),
            placement_state(&client),
            "snapshot={}",
            String::from_utf8_lossy(&snapshot)
        );
        assert_eq!(
            crate::terminal_text::capture(source, 20, true).unwrap(),
            crate::terminal_text::capture(&client, 20, true).unwrap()
        );
        assert_eq!(source.cursor_x().unwrap(), client.cursor_x().unwrap());
        assert_eq!(source.cursor_y().unwrap(), client.cursor_y().unwrap());
        assert_eq!(
            source.is_cursor_pending_wrap().unwrap(),
            client.is_cursor_pending_wrap().unwrap()
        );
        client
    }
    #[test]
    fn large_images_crop_layers_and_virtual_placements() {
        let mut source = terminal();
        let pixels: Vec<u8> = (0..256 * 256 * 4)
            .map(|n| ((n * 37 + n / 17) % 256) as u8)
            .collect();
        source.vt_write(
            format!(
                "\x1b_Ga=t,f=32,s=256,v=256,i=55,q=2;{}\x1b\\",
                B64.encode(&pixels)
            )
            .as_bytes(),
        );
        source.vt_write(b"\x1b_Ga=p,i=55,p=9,c=6,r=2,x=1,y=2,w=80,h=40,X=2,Y=3,z=-1,C=1,q=2\x1b\\");
        source.vt_write(b"\x1b_Ga=p,i=55,p=10,U=1,c=2,r=1,q=2\x1b\\");
        assert_eq!(placement_state(&source).len(), 2);
        let client = roundtrip(&source, &BTreeSet::new());
        let graphics = client.kitty_graphics().unwrap().unwrap();
        assert_eq!(graphics.image(55).unwrap().data().unwrap(), Some(pixels.as_slice()));
        let mut iterator = kg::PlacementIterator::new().unwrap();
        let mut placements = iterator.update(&graphics).unwrap();
        while let Some(p) = placements.next() {
            if p.placement_id().unwrap() == 9 {
                assert_eq!(
                    (
                        p.source_x().unwrap(),
                        p.source_y().unwrap(),
                        p.source_width().unwrap(),
                        p.source_height().unwrap()
                    ),
                    (1, 2, 80, 40)
                );
            }
        }
    }
    #[test]
    fn numbered_upload_without_placement_survives_attach() {
        let mut source = terminal();
        let mut state = State::default();
        let bytes = b"\x1b_Ga=t,f=32,s=2,v=1,I=777,q=2;/wAA/wD/AP8=\x1b\\";
        state.header("a=t,I=777", &source);
        state.feed(bytes);
        source.vt_write(bytes);
        state.prune(&mut source);
        assert!(
            placement_state(&source).is_empty(),
            "ID lookup must leave no placement"
        );
        assert!(
            state.external_upload,
            "Image numbers are interpreted only on the authority"
        );
        let bytes = state
            .capture(&source, crate::checkpoint::capture(&source).unwrap())
            .unwrap();
        let mut client = terminal();
        client.vt_write(&bytes);
        let id = *state.ids[0].first().unwrap();
        assert!(client.kitty_graphics().unwrap().unwrap().image(id).is_some());
        source.vt_write(b"\x1b_Ga=p,I=777,p=5,c=3,r=2,q=2\x1b\\");
        // A numbered command advances the stream generation, so clients receive
        // this authoritative state instead of interpreting I= against local IDs.
        let bytes = state
            .capture(&source, crate::checkpoint::capture(&source).unwrap())
            .unwrap();
        client.vt_write(&bytes);
        assert_eq!(placement_state(&source).len(), 1);
        assert_eq!(placement_state(&source), placement_state(&client));
    }
    #[test]
    fn server_file_decode_is_shared_and_snapshot_outlives_file() {
        DECODE_CACHE.with_borrow_mut(|cache| *cache = DecodeCache::default());
        let file = std::env::temp_dir().join(format!(
            "tty-graphics-protocol-{}.png",
            uuid::Uuid::new_v4()
        ));
        let png=B64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==").unwrap();
        std::fs::write(&file, &png).unwrap();
        let path = B64.encode(file.to_string_lossy().as_bytes());
        let mut first = terminal();
        let mut second = terminal();
        for vt in [&mut first, &mut second] {
            vt.vt_write(
                format!("\x1b_Ga=T,t=f,f=100,i=91,p=1,c=2,r=2,q=2;{path}\x1b\\").as_bytes(),
            );
            assert_eq!(placement_state(vt).len(), 1);
        }
        assert_eq!(
            DECODE_CACHE.with_borrow(|cache| cache.decodes),
            1,
            "Identical file contents decode once across terminals"
        );
        std::fs::remove_file(file).unwrap();
        for _ in 0..3 {
            let bytes = snapshot(
                &first,
                crate::checkpoint::capture(&first).unwrap(),
                &BTreeSet::new(),
            )
            .unwrap();
            assert!(!String::from_utf8_lossy(&bytes).contains("t=f"));
        }
        assert_eq!(
            DECODE_CACHE.with_borrow(|cache| cache.decodes),
            1,
            "Client snapshots never reread or decode the source file"
        );
        roundtrip(&first, &BTreeSet::new());
        roundtrip(&second, &BTreeSet::new());
    }
    #[test]
    fn external_upload_waits_until_safe_to_send_inline_snapshot() {
        let mut state = State::default();
        let vt = terminal();
        state.feed(b"\x1b_Ga=T,t=f,f=100,i=3;L3RtcC8=");
        state.header("a=T,t=f,f=100,i=3", &vt);
        assert!(!state.stream_ready());
        state.feed(b"\x1b");
        assert!(!state.stream_ready());
        state.feed(b"\\");
        assert!(state.stream_ready());
    }

    #[test]
    fn attach_in_the_middle_of_a_chunked_upload() {
        let first = b"\x1b_Ga=T,f=32,s=2,v=1,i=77,p=7,c=3,r=2,q=2,m=1;/wAA\x1b\\";
        let last = b"\x1b_Gm=0,q=2;/wD/AP8=\x1b\\";
        for split in 1..first.len() + last.len() {
            let all = [first.as_slice(), last.as_slice()].concat();
            let mut source = terminal();
            let mut state = State::default();
            state.header("i=77", &source);
            state.feed(&all[..split]);
            source.vt_write(&all[..split]);
            let bytes = state
                .capture(&source, crate::checkpoint::capture(&source).unwrap())
                .unwrap();
            let mut client = terminal();
            client.vt_write(&bytes);
            source.vt_write(&all[split..]);
            client.vt_write(&all[split..]);
            assert_eq!(
                placement_state(&source),
                placement_state(&client),
                "split={split}"
            );
            assert_eq!(placement_state(&client).len(), 1);
        }
    }
    #[test]
    fn pixels_placements_history_and_future_deletes() {
        let mut source = terminal();
        source.vt_write(b"first\r\n");
        image(&mut source, 41, true);
        for i in 0..12 {
            source.vt_write(format!("row {i} 한글\r\n").as_bytes());
        }
        image(&mut source, 42, true);
        source.vt_write(b"last");
        let mut client = roundtrip(&source, &BTreeSet::new());
        for vt in [&mut source, &mut client] {
            vt.vt_write(b"\x1b_Ga=d,d=I,i=42,q=2\x1b\\next\r\n");
        }
        assert_eq!(placement_state(&source), placement_state(&client));
        roundtrip(&source, &BTreeSet::new());
    }
    #[test]
    fn unplaced_image_can_be_placed_after_attach() {
        let mut source = terminal();
        image(&mut source, 43, false);
        let mut client = roundtrip(&source, &BTreeSet::from([43]));
        for vt in [&mut source, &mut client] {
            vt.vt_write(b"\x1b_Ga=p,i=43,p=8,c=4,r=2,q=2\x1b\\");
        }
        assert!(!placement_state(&source).is_empty());
        assert_eq!(placement_state(&source), placement_state(&client));
    }
    #[test]
    fn alternate_screen_and_soft_wrapped_rows() {
        for prefix in [b"".as_slice(), b"\x1b[?1049h".as_slice()] {
            let mut source = terminal();
            source.vt_write(prefix);
            source.vt_write("가나다라마바사아자차".as_bytes());
            image(&mut source, 44, true);
            source.vt_write("카타파하ABCDEFGHIJKLMNOPQRSTUVWXYZ한글".as_bytes());
            roundtrip(&source, &BTreeSet::new());
        }
    }
    #[test]
    fn sixel_and_iterm_use_authoritative_storage() {
        let mut source = terminal();
        let (png, w, h) = crate::inline_images::sixel(b"0;1q\"1;1;2;6#1;2;100;0;0!2~").unwrap();
        crate::inline_images::place(&mut source, &png, w, h, CELL);
        let mut images = crate::inline_images::Images::default();
        images.iterm(
            &format!("File=inline=1;width=2;height=2:{}", B64.encode(png)),
            &mut source,
            CELL,
            inline_decode,
        );
        assert_eq!(placement_state(&source).len(), 2);
        roundtrip(&source, &BTreeSet::new());
    }
}
