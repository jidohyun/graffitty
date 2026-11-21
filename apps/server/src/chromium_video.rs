//! Encode outside the session/input loop. Renditions are shared by codec;
//! bounded reference-packet history allows slow/late clients to restart at a keyframe.
use graffitty_chromium_video::{Codec, Encoded, Encoder};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

/// Give each video pipeline a unique generation. When Chromium restarts,
/// this makes the client start from a keyframe using the new numbering.
fn next_epoch() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// A client preference; zero means automatic. Bound untrusted requests before allocating.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Quality { pub max_height: u32, pub fps: u32, pub bitrate_kbps: u32 }
/// Automatic resolution stops here; clients choose 2160 explicitly. A tablet
/// presenting a portrait 2160p pane spent its whole frame on decoding,
/// uploading and drawing it; 1440p kept that budget for the workspace.
const AUTO_MAX_HEIGHT: u32 = 1440;
/// Below this a moving page is unreadable; a slower link loses frames instead.
const MIN_ADAPTED_KBPS: u32 = 300;
impl Quality {
    pub fn parse(value: &serde_json::Value) -> Self {
        // JSON clients may write integral limits as 1440.0.
        let integer = |v: &serde_json::Value| v.as_u64().or_else(|| v.as_f64()
            .filter(|f| f.is_finite() && *f >= 0.0 && f.fract() == 0.0 && *f <= u32::MAX as f64).map(|f| f as u64));
        let bounded = |key: &str, min, max| integer(&value[key]).filter(|v| *v>0).map(|v| v.clamp(min,max) as u32).unwrap_or(0);
        Self {max_height:bounded("max_height", 144, 2160), fps:bounded("fps", 1, 60), bitrate_kbps:bounded("bitrate_kbps", 500, 200_000)}
    }
    pub fn for_viewport(self, id: u64, viewports: &HashMap<u64, u32>) -> Self {
        let Some(&height) = viewports.get(&id) else { return self; };
        let mut quality = self;
        quality.max_height = if self.max_height == 0 { height.min(AUTO_MAX_HEIGHT) } else { self.max_height.min(height) };
        // The configured bitrate is a connection budget shared by its visible
        // browser panes. Automatic quality also bounds small-pane bandwidth.
        quality.bitrate_kbps = (if self.bitrate_kbps == 0 { 20_000 } else { self.bitrate_kbps })
            / viewports.len().max(1) as u32;
        if self.bitrate_kbps == 0 {
            let estimate = (quality.max_height as u64 * quality.max_height as u64 * 16 * 8 / 9 / 1000)
                .clamp(500, 20_000) as u32;
            quality.bitrate_kbps = quality.bitrate_kbps.min(estimate);
        }
        quality.bitrate_kbps = quality.bitrate_kbps.max(1);
        quality
    }
    /// This quality at `share` of its bitrate, never below a usable floor.
    /// Automatic quality without a viewport has no bitrate to scale.
    pub fn adapted(self, share: f32) -> Self {
        if self.bitrate_kbps == 0 || share >= 1.0 { return self; }
        Self { bitrate_kbps: ((self.bitrate_kbps as f32 * share) as u32).max(MIN_ADAPTED_KBPS.min(self.bitrate_kbps)), ..self }
    }
    fn size(self, width:u32, height:u32)->(u32,u32) {
        let target=height.min(if self.max_height>0 {self.max_height} else {AUTO_MAX_HEIGHT});
        (((width as u64*target as u64/height as u64) as u32 & !1).max(16), (target & !1).max(16))
    }
    #[cfg(any(not(target_os = "macos"), test))]
    fn size_with_minimum(self, width: u32, height: u32, minimum: (u32, u32)) -> Option<(u32, u32)> {
        let requested = self.size(width, height);
        if requested.0 >= minimum.0 && requested.1 >= minimum.1 { return Some(requested); }
        // A tiny projected pane can be narrower than the encoder's minimum.
        // Retain its aspect ratio, using only enough pixels for that hardware.
        let target = u64::from(requested.1.max(minimum.1))
            .max((u64::from(minimum.0) * u64::from(height)).div_ceil(u64::from(width)));
        let h = (target + 1) & !1;
        let w = ((u64::from(width) * h).div_ceil(u64::from(height)) + 1) & !1;
        (w <= 4096 && h <= 4096).then_some((w as u32, h as u32))
    }
    fn fps(self)->u32 {if self.fps==0 {60} else {self.fps}}
}

/// A client's displayed chromium panes: physical height tiers per pane, and
/// the panes it paused because they are off-screen or too small to read.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Viewports {
    pub displayed: HashMap<u64, u32>,
    pub paused: HashSet<u64>,
}

/// Physical display height is rendition demand, not the shared page's CSS
/// size.
///
/// Height zero pauses the pane for this client: it receives no frames, and
/// the pane does not count toward its rendition or the connection's bitrate
/// budget.
pub fn parse_viewports(
    value: &serde_json::Value,
    mut visible: impl FnMut(u64) -> bool,
) -> Result<Viewports, String> {
    let views = value.as_object().ok_or("Expected chromium viewports")?;
    if views.len() > 32 { return Err("Too many chromium viewports".into()); }
    let mut result = Viewports::default();
    for (id, height) in views {
        let id = id.parse::<u64>().map_err(|_| "Invalid chromium viewport session")?;
        let height = height.as_u64().ok_or("Invalid chromium viewport height")?;
        if !visible(id) { continue; }
        if height == 0 {
            result.paused.insert(id);
            continue;
        }
        let bucket = [144, 240, 360, 540, 720, 1080, 1440, 2160].into_iter()
            .find(|&bucket| bucket >= height.clamp(144, 2160)).unwrap_or(2160);
        result.displayed.insert(id, bucket as u32);
    }
    Ok(result)
}

pub fn changed_viewports(
    quality: Quality,
    previous: &HashMap<u64, u32>,
    next: &HashMap<u64, u32>,
) -> HashSet<u64> {
    previous.keys().chain(next.keys()).copied().filter(|&id| {
        quality.for_viewport(id, previous) != quality.for_viewport(id, next)
    }).collect()
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Stream {pub codec:Codec, pub quality:Quality, pub pacing:u64}
impl From<Codec> for Stream {fn from(codec:Codec)->Self {Self {codec,quality:Quality::default(),pacing:0}}}

#[derive(Clone)]
pub enum Source {
    Image(Arc<Vec<u8>>),
    Surface(Arc<graffitty_chromium_video::surface::Surface>),
}
enum VideoEncoder {
    Pixels(Encoder),
    Surface(graffitty_chromium_video::surface::SurfaceEncoder),
}
impl VideoEncoder {
    fn new(codec: Codec, width: u32, height: u32, source: &Source, quality:Quality) -> Result<Self, String> {
        match source {
            Source::Image(_) => Encoder::configured(codec, width, height, quality.bitrate_kbps*1000, quality.fps()).map(Self::Pixels),
            #[cfg(not(target_os = "macos"))]
            Source::Surface(surface) => {
                graffitty_chromium_video::surface::SurfaceEncoder::configured(surface, codec, width, height, quality.bitrate_kbps*1000, quality.fps())
                    .map(Self::Surface)
            }
            #[cfg(target_os = "macos")]
            Source::Surface(_) => {
                graffitty_chromium_video::surface::SurfaceEncoder::configured(codec, width, height, quality.bitrate_kbps*1000, quality.fps())
                    .map(Self::Surface)
            }
        }
    }
    /// Live rate change: no new session and no keyframe where the platform
    /// encoder supports it (VideoToolbox, NVENC).
    fn set_bitrate(&mut self, quality: Quality) {
        if quality.bitrate_kbps == 0 { return; }
        match self {
            Self::Pixels(e) => e.set_bitrate(quality.bitrate_kbps * 1000),
            Self::Surface(e) => e.set_bitrate(quality.bitrate_kbps * 1000),
        }
    }
    fn encode(
        &mut self,
        source: &Source,
        pixels: Option<&image::RgbaImage>,
        key: bool,
    ) -> Result<Option<Encoded>, String> {
        match (self, source) {
            (Self::Pixels(e), Source::Image(_)) => {
                e.encode(pixels.ok_or("Missing raw pixels")?.as_raw(), key)
            }
            (Self::Surface(e), Source::Surface(surface)) => e.encode(surface, key),
            #[allow(unreachable_patterns)]
            _ => Err("Capture source changed".into()),
        }
    }
}
#[derive(Clone)]
pub struct Packet {
    pub sequence: u64,
    pub epoch: u64,
    pub width: u32,
    pub height: u32,
    pub source_width: u32,
    pub source_height: u32,
    pub key: bool,
    pub bytes: Arc<Vec<u8>>,
}
#[derive(Default)]
pub struct Rendition {
    pub packets: VecDeque<Packet>,
    pub failed: Option<Instant>,
    bytes: usize,
}
#[derive(Default)]
struct Shared {
    source: Option<(u64, Source)>,
    preview_source: Option<(u64, Source)>,
    png: bool,
    png_preview: Option<(u64, Arc<Vec<u8>>)>,
    wanted: HashSet<Stream>,
    /// Renditions whose clients cannot take a frame yet; see `Flow::saturated`.
    paused: HashSet<Stream>,
    keyframes: HashSet<Stream>,
    /// The share of its bitrate each rendition's viewers' links carry.
    shares: HashMap<Stream, f32>,
    streams: HashMap<Stream, Rendition>,
}
pub struct Pipeline {
    shared: Arc<Mutex<Shared>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
    preview_worker: Option<thread::JoinHandle<()>>,
}
impl Pipeline {
    pub fn new() -> Self {
        let shared = Arc::new(Mutex::new(Shared::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let (state, stopping) = (shared.clone(), stop.clone());
        let worker = thread::spawn(move || {
            // Opt-in: why a captured frame did or did not become a packet.
            let trace = std::env::var("RUST_LOG").is_ok_and(|v| v.contains("graffitty_video"));
            // Encoder, size, epoch, sequence, last encode, revision, bitrate share.
            let mut encoders: HashMap<Stream, (VideoEncoder, u32, u32, u64, u64, Instant, u64, f32)> = HashMap::new();
            let mut last = None;
            // The newest revision already reported as held, so each is traced once.
            let mut held = None;
            while !stopping.load(Ordering::Relaxed) {
                let (source, wanted, paused, keys, shares) = {
                    let mut s = state.lock().unwrap();
                    (
                        s.source.clone(),
                        s.wanted.clone(),
                        s.paused.clone(),
                        std::mem::take(&mut s.keyframes),
                        s.shares.clone(),
                    )
                };
                encoders.retain(|codec, _| wanted.contains(codec));
                if source.is_some() {
                    last = source.clone();
                }
                if trace && wanted.is_empty() {
                    if let Some((revision, _)) = &last {
                        if held != Some(*revision) {
                            held = Some(*revision);
                            eprintln!("video holds revision {revision}: no client wants a rendition");
                        }
                    }
                }
                if wanted.is_empty()
                    || (source.is_none()
                        && keys.is_empty()
                        && wanted.iter().all(|c| {
                            encoders.contains_key(c)
                                || state
                                    .lock()
                                    .unwrap()
                                    .streams
                                    .get(c)
                                    .is_some_and(|s| s.failed.is_some())
                        }))
                {
                    thread::sleep(Duration::from_millis(4));
                    continue;
                }
                let Some((revision, frame)) = &last else {
                    thread::sleep(Duration::from_millis(4));
                    continue;
                };
                // A paused rendition encodes the newest page once its client
                // can take it; its previous frame remains the reference.
                let idle = |stream: &Stream, e: &(VideoEncoder, u32, u32, u64, u64, Instant, u64, f32)| {
                    e.6 == *revision || paused.contains(stream)
                        || e.5.elapsed() < Duration::from_secs_f64(1.0 / stream.quality.fps() as f64)
                };
                if keys.is_empty() && wanted.iter().all(|stream| {
                    encoders.get(stream).is_some_and(|e| idle(stream, e))
                    || state.lock().unwrap().streams.get(stream).is_some_and(|s| s.failed.is_some())
                }) {
                    if trace && held != Some(*revision)
                        && encoders.values().all(|e| e.6 != *revision)
                    {
                        held = Some(*revision);
                        eprintln!("video holds revision {revision}: {} of {} renditions paused",
                            wanted.iter().filter(|stream| paused.contains(stream)).count(), wanted.len());
                    }
                    thread::sleep(Duration::from_millis(4));
                    continue;
                }
                #[cfg(target_os = "macos")]
                let aligned;
                #[cfg(target_os = "macos")]
                let frame=if let Source::Surface(surface)=frame {
                    aligned=match surface.video_aligned() {
                        Ok(surface)=>Source::Surface(Arc::new(surface)),
                        Err(error)=>{eprintln!("Chromium video alignment: {error}");continue;}
                    };
                    &aligned
                } else {frame};
                // PNG fallback readback runs on another worker and
                // cannot stall hardware video or the input/control loop.
                let mut pixels = match frame {
                    Source::Image(bytes) => {
                        image::load_from_memory(bytes).ok().map(|im| im.to_rgba8())
                    }
                    Source::Surface(_) => None,
                };
                let (width, height) = match frame {
                    Source::Image(_) => {
                        let Some(image) = &mut pixels else {
                            continue;
                        };
                        let (w, h) = (image.width() & !1, image.height() & !1);
                        *image = image::imageops::crop(image, 0, 0, w, h).to_image();
                        (w, h)
                    }
                    Source::Surface(surface) => (surface.width, surface.height),
                };
                // A GPU surface is scaled to its rendition on the GPU, so it
                // may be as large as the capture slot allows: the Chrome
                // backend captures at the display scale, 1920x4884 for a
                // portrait tablet pane.
                //
                // Decoded images stay bounded for their CPU copy.
                let limit = if matches!(frame, Source::Surface(_)) { 8192 } else { 4096 };
                if width < 16 || height < 16 || width > limit || height > limit {
                    if trace && held != Some(*revision) {
                        held = Some(*revision);
                        eprintln!("video skips revision {revision}: {width}x{height} is outside 16..{limit}");
                    }
                    continue;
                }
                let (source_width,source_height)=(width,height);
                // Shared viewers must not wait for every independently paced
                // viewer to encode the same revision. Service shared streams
                // first, then the oldest private streams within one frame's
                // budget.
                //
                // Deferred private streams retain their reference history and
                // pick up the newest capture on the next pass.
                let mut wanted: Vec<_> = wanted.into_iter().collect();
                wanted.sort_by_key(|stream| (stream.pacing != 0, encoders.get(stream).map(|e| e.5)));
                let batch_started = Instant::now();
                for codec in wanted {
                    let force=keys.contains(&codec);
                    if codec.pacing != 0 && batch_started.elapsed() >= Duration::from_micros(16_667) {
                        if force { state.lock().unwrap().keyframes.insert(codec); }
                        continue;
                    }
                    if encoders.get(&codec).is_some_and(|e| !force && idle(&codec, e)) {
                        if trace && encoders.get(&codec).is_some_and(|e| e.6 != *revision) {
                            eprintln!("video {:?} holds revision {revision}: paused={}", codec.codec,
                                paused.contains(&codec));
                        }
                        continue;
                    }
                    let dimensions = codec.quality.size(width, height);
                    #[cfg(not(target_os = "macos"))]
                    let dimensions = if let Source::Surface(surface) = frame {
                        graffitty_chromium_video::surface::SurfaceEncoder::minimum_size(surface, codec.codec)
                            .and_then(|minimum| codec.quality.size_with_minimum(width, height, minimum))
                            .unwrap_or(dimensions)
                    } else { dimensions };
                    let (width, height) = dimensions;
                    let resized_pixels=pixels.as_ref().filter(|p| p.dimensions()!=(width,height)).map(|p| image::imageops::resize(p,width,height,image::imageops::FilterType::Triangle));
                    #[cfg(target_os="macos")]
                    let scaled;
                    #[cfg(target_os="macos")]
                    let frame=if let Source::Surface(surface)=frame {
                        scaled=match surface.scaled(width,height) {Ok(s)=>Source::Surface(Arc::new(s)),Err(error)=>{eprintln!("Chromium scaling: {error}");continue;}};
                        &scaled
                    } else {frame};
                    if state
                        .lock()
                        .unwrap()
                        .streams
                        .get(&codec)
                        .is_some_and(|s| s.failed.is_some())
                    {
                        continue;
                    }
                    let share = shares.get(&codec).copied().unwrap_or(1.0);
                    let recreate = encoders
                        .get(&codec)
                        .is_none_or(|e| (e.1, e.2) != (width, height));
                    // The viewer's link changed its bitrate tier: the live
                    // encoder takes the new rate. Reopening it would cost a
                    // keyframe, which a narrow link cannot carry.
                    if !recreate {
                        if let Some(e) = encoders.get_mut(&codec).filter(|e| e.7 != share) {
                            e.0.set_bitrate(codec.quality.adapted(share));
                            e.7 = share;
                            if trace {
                                eprintln!("video {:?} bitrate {} kbps", codec.codec, codec.quality.adapted(share).bitrate_kbps);
                            }
                        }
                    }
                    if recreate {
                        // Release this rendition's slot before allocating its
                        // replacement; a full hardware pool must still resize.
                        encoders.remove(&codec);
                        match VideoEncoder::new(codec.codec, width, height, frame, codec.quality.adapted(share)) {
                            Ok(encoder) => {
                                let epoch = next_epoch();
                                encoders.insert(codec, (encoder, width, height, epoch, 0, Instant::now(), u64::MAX, share));
                                state
                                    .lock()
                                    .unwrap()
                                    .streams
                                    .insert(codec, Rendition::default());
                            }
                            Err(error) => {
                                eprintln!("Chromium {:?} encoder initialization: {}", codec, error);
                                state
                                    .lock()
                                    .unwrap()
                                    .streams
                                    .entry(codec)
                                    .or_default()
                                    .failed = Some(Instant::now());
                                continue;
                            }
                        }
                    }
                    let e = encoders.get_mut(&codec).unwrap();
                    e.5=Instant::now(); e.6=*revision;
                    match e
                        .0
                        .encode(frame, resized_pixels.as_ref().or(pixels.as_ref()), recreate || force)
                    {
                        Ok(Some(packet)) => {
                            e.4 += 1;
                            let packet = Packet {
                                sequence: e.4,
                                epoch: e.3,
                                width,
                                height,
                                source_width, source_height,
                                key: packet.key,
                                bytes: Arc::new(packet.bytes),
                            };
                            if trace {
                                eprintln!("video {:?} revision {revision} packet epoch {} sequence {} key {}",
                                    codec.codec, packet.epoch, packet.sequence, packet.key);
                            }
                            let mut s = state.lock().unwrap();
                            let stream = s.streams.entry(codec).or_default();
                            stream.bytes += packet.bytes.len();
                            stream.packets.push_back(packet);
                            while stream.packets.len() > 90 || stream.bytes > 16 * 1024 * 1024 {
                                if let Some(old) = stream.packets.pop_front() {
                                    stream.bytes -= old.bytes.len();
                                }
                            }
                            drop(s);
                            // Deliver now rather than at the session loop's next timeout.
                            crate::wake::notify();
                        }
                        Ok(None) => {
                            // Rate control dropped the frame. Encode this page
                            // again on the next pass, as an ordinary frame: a
                            // keyframe at a starved rate would only be dropped too.
                            if trace { eprintln!("video {:?} revision {revision} produced no packet", codec.codec); }
                            e.6 = u64::MAX;
                        }
                        Err(error) => {
                            eprintln!("Chromium {:?} encoding: {}", codec, error);
                            state
                                .lock()
                                .unwrap()
                                .streams
                                .entry(codec)
                                .or_default()
                                .failed = Some(Instant::now());
                        }
                    }
                }
                thread::sleep(Duration::from_millis(2));
            }
        });
        let (state, stopping) = (shared.clone(), stop.clone());
        let preview_worker = thread::spawn(move || {
            let mut next_preview = Instant::now();
            while !stopping.load(Ordering::Relaxed) {
                let pending = {
                    let shared = state.lock().unwrap();
                    shared.preview_source.as_ref().filter(|(revision, _)| {
                        shared.png && Instant::now() >= next_preview &&
                            shared.png_preview.as_ref().is_none_or(|(sent, _)| sent != revision)
                    }).cloned()
                };
                let Some((revision, frame)) = pending else {
                    thread::sleep(Duration::from_millis(8));
                    continue;
                };
                next_preview = Instant::now() + Duration::from_millis(100);
                let bytes = match frame {
                    Source::Image(bytes) if bytes.starts_with(b"\x89PNG\r\n\x1a\n") => bytes,
                    other => {
                        let pixels = match other {
                            Source::Image(bytes) => image::load_from_memory(&bytes).ok().map(|im| im.to_rgba8()),
                            Source::Surface(surface) => surface.rgba().ok().and_then(|rgba| {
                                image::RgbaImage::from_raw(surface.width, surface.height, rgba)
                            }),
                        };
                        let Some(image) = pixels else { continue };
                        let mut bytes = std::io::Cursor::new(Vec::new());
                        if image.write_to(&mut bytes, image::ImageFormat::Png).is_err() { continue; }
                        Arc::new(bytes.into_inner())
                    }
                };
                // Pace by encoded size toward 1 MiB/s, with a one-second
                // maximum delay so a large repaint keeps the pane interactive.
                next_preview = next_preview.max(Instant::now() +
                    Duration::from_secs_f64((bytes.len() as f64 / 1048576.0).min(1.0)));
                let mut shared = state.lock().unwrap();
                if shared.png { shared.png_preview = Some((revision, bytes)); }
            }
        });
        Self {
            shared,
            stop,
            worker: Some(worker),
            preview_worker: Some(preview_worker),
        }
    }
    pub fn source(&self, revision: u64, bytes: Source) {
        let mut s = self.shared.lock().unwrap();
        s.source = Some((revision, bytes.clone()));
        s.preview_source = Some((revision, bytes));
    }
    // Local GPU sharing (chromium_gpu) has no Linux transport yet; video serves those clients.
    #[cfg(any(target_os = "macos", windows))]
    pub fn surface(&self) -> Option<(u64, Arc<graffitty_chromium_video::surface::Surface>)> {
        let s = self.shared.lock().unwrap();
        match &s.preview_source {
            Some((revision, Source::Surface(surface))) => Some((*revision, surface.clone())),
            _ => None,
        }
    }
    pub fn preview(&self) -> Option<(u64, Arc<Vec<u8>>)> {
        self.shared.lock().unwrap().png_preview.clone()
    }
    pub fn demand(&self, codecs: HashSet<Stream>, paused: HashSet<Stream>, shares: HashMap<Stream, f32>, png: bool) {
        let mut s = self.shared.lock().unwrap();
        s.paused = paused;
        s.shares = shares;
        if s.png != png {
            s.png_preview = None;
        }
        s.png = png;
        let added: Vec<_> = codecs.difference(&s.wanted).copied().collect();
        s.keyframes.extend(added);
        s.streams
            .retain(|codec, stream| codecs.contains(codec) || stream.failed.is_some());
        s.wanted = codecs;
    }
    /// Failed encoders remain disabled for their subscribed pacing group, but
    /// disconnecting a private viewer must also retire its failure records.
    pub fn retain_pacing(&self, active: &HashSet<u64>) {
        self.shared.lock().unwrap().streams.retain(|stream, _| stream.pacing == 0 || active.contains(&stream.pacing));
    }
    pub fn available(&self, client: &[Codec], quality:Quality, pacing:u64) -> Option<Stream> {
        self.available_at(client, quality, pacing, Instant::now())
    }
    fn available_at(&self, client: &[Codec], quality:Quality, pacing:u64, now:Instant) -> Option<Stream> {
        let available = graffitty_chromium_video::encoders(client);
        let supported: Vec<_> = Codec::PREFERENCE.into_iter()
            .filter(|codec| client.contains(codec) && available.contains(codec))
            .map(|codec| Stream {codec,quality,pacing}).collect();
        let mut s = self.shared.lock().unwrap();
        // Retry allocation at a bounded rate while no codec works. Hardware
        // sessions may be temporarily exhausted.
        //
        // Once a fallback codec works, keep it running.
        let working = supported.iter().any(|stream| s.streams.get(stream)
            .is_some_and(|r| r.failed.is_none() && !r.packets.is_empty()));
        for stream in supported {
            if let Some(failed) = s.streams.get(&stream).and_then(|r| r.failed) {
                if working || now.saturating_duration_since(failed) < Duration::from_secs(5) { continue; }
                s.streams.remove(&stream);
            }
            return Some(stream);
        }
        None
    }
    pub fn next(&self, codec: Stream, epoch: u64, sequence: u64) -> Option<Packet> {
        let mut s = self.shared.lock().unwrap();
        let stream = s.streams.get(&codec)?;
        // A new encoder's first keyframe is still being encoded. Requesting
        // another would encode a second keyframe, even for a paused rendition.
        if stream.packets.is_empty() && stream.failed.is_none() {
            return None;
        }
        let behind = stream
            .packets
            .back()
            .is_some_and(|p| p.epoch == epoch && p.sequence > sequence + 6);
        if !behind {
            if let Some(packet) = stream
                .packets
                .iter()
                .find(|p| p.epoch == epoch && p.sequence == sequence + 1)
            {
                return Some(packet.clone());
            }
        }
        if stream
            .packets
            .back()
            .is_some_and(|p| p.epoch == epoch && p.sequence == sequence)
        {
            return None;
        }
        // A new subscription or overwritten history must start at a recent IDR.
        if let Some(packet) = stream.packets.iter().rev().find(|p| {
            p.key
                && (p.epoch != epoch || p.sequence > sequence)
                && stream
                    .packets
                    .back()
                    .is_some_and(|latest| latest.sequence - p.sequence <= 6)
        }) {
            return Some(packet.clone());
        }
        s.keyframes.insert(codec);
        None
    }
}
impl Drop for Pipeline {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        if let Some(worker) = self.preview_worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn viewport_buckets_validate_and_filter_visible_sessions() {
        let views = parse_viewports(&serde_json::json!({"1": 80, "2": 200, "3": 361, "4": 99999}), |id| id < 4).unwrap();
        assert_eq!(views.displayed, HashMap::from([(1, 144), (2, 240), (3, 540)]));
        assert!(views.paused.is_empty());
        let paused = parse_viewports(&serde_json::json!({"1": 0, "2": 1, "5": 0}), |id| id < 4).unwrap();
        assert_eq!(paused.displayed, HashMap::from([(2, 144)]), "Any displayed height keeps the smallest tier");
        assert_eq!(paused.paused, HashSet::from([1]), "Zero pauses only panes this client may view");
        assert!(parse_viewports(&serde_json::json!({"bad": 360}), |_| true).is_err());
        assert!(parse_viewports(&serde_json::json!({"1": "360"}), |_| true).is_err());
        assert!(parse_viewports(&serde_json::json!([]), |_| true).is_err());
    }
    #[test]
    fn viewport_changes_preserve_unaffected_and_equivalent_renditions() {
        let base = Quality::default();
        let previous = parse_viewports(&serde_json::json!({"1": 1000, "2": 360}), |_| true).unwrap().displayed;
        let same = parse_viewports(&serde_json::json!({"1": 1080, "2": 350}), |_| true).unwrap().displayed;
        assert!(changed_viewports(base, &previous, &same).is_empty());
        let next = parse_viewports(&serde_json::json!({"1": 540, "2": 360}), |_| true).unwrap().displayed;
        assert_eq!(changed_viewports(base, &previous, &next), HashSet::from([1]));
        let capped = Quality { max_height: 360, ..base };
        assert!(changed_viewports(capped, &previous, &next).is_empty());
    }
    #[test]
    fn viewport_budget_changes_invalidate_all_affected_panes_but_are_per_client() {
        let base = Quality { bitrate_kbps: 6000, fps: 30, ..Quality::default() };
        let previous = HashMap::from([(1, 1080), (2, 360)]);
        let next = HashMap::from([(1, 1080)]);
        assert_eq!(changed_viewports(base, &previous, &next), HashSet::from([1, 2]));
        assert_eq!(base.for_viewport(1, &previous).bitrate_kbps, 3000);
        assert_eq!(base.for_viewport(1, &next).bitrate_kbps, 6000);
        assert_eq!(base.for_viewport(1, &next).fps, 30);
        let other_client = HashMap::from([(1, 240)]);
        assert_eq!(Quality::default().for_viewport(1, &other_client).max_height, 240);
        assert_eq!(base.for_viewport(1, &previous).max_height, 1080);
        let tall = HashMap::from([(1, 2160)]);
        assert_eq!(Quality::default().for_viewport(1, &tall).max_height, 1440, "Auto stops at 1440p");
        assert_eq!(Quality { max_height: 2160, ..base }.for_viewport(1, &tall).max_height, 2160);
    }
    #[test]
    fn adapted_quality_scales_bitrate_to_a_floor() {
        let quality = Quality { bitrate_kbps: 6000, fps: 60, max_height: 1440 };
        assert_eq!(quality.adapted(1.0), quality);
        assert_eq!(quality.adapted(0.5).bitrate_kbps, 3000);
        assert_eq!(quality.adapted(0.01).bitrate_kbps, MIN_ADAPTED_KBPS);
        assert_eq!(Quality { bitrate_kbps: 200, ..quality }.adapted(0.5).bitrate_kbps, 200, "Never above the configured budget");
        assert_eq!(Quality::default().adapted(0.5), Quality::default(), "Automatic quality without a viewport is unchanged");
        assert_eq!(quality.adapted(0.5).max_height, 1440, "Resolution and frame rate are kept");
    }

    #[test]
    fn quality_bounds_and_aspect_ratio() {
        let q=Quality::parse(&serde_json::json!({"fps":999999,"max_height":999999,"bitrate_kbps":9999999999u64}));
        assert_eq!(q, Quality {fps:60,max_height:2160,bitrate_kbps:200_000});
        let saved=Quality::parse(&serde_json::json!({"max_height":1440.0,"fps":30.0,"bitrate_kbps":0.5}));
        assert_eq!(saved, Quality {fps:30,max_height:1440,bitrate_kbps:0}, "Integral floats from JSON clients are limits; fractions are not");
        assert_eq!(Quality::default().size(1600,900),(1600,900));
        assert_eq!(Quality::default().size(1000,2700),(532,1440), "Auto stops at 1440p");
        assert_eq!(Quality {max_height:2160,..Quality::default()}.size(1000,2700),(800,2160), "2160p is explicit");
        let small=Quality {max_height:360,..Quality::default()};
        assert_eq!(small.size(1600,900),(640,360));
        assert_eq!(small.size(320,180),(320,180));
        assert_eq!(small.size(1000,700),(514,360));
    }
    #[test]
    fn hardware_minimum_preserves_tall_page_aspect_and_allocation_bounds() {
        let tiny = Quality {max_height: 240, ..Quality::default()};
        assert_eq!(tiny.size(1280, 3250), (94, 240));
        assert_eq!(tiny.size_with_minimum(1280, 3250, (144, 128)), Some((146, 366)));
        assert_eq!(tiny.size_with_minimum(1920, 1080, (144, 128)), Some((426, 240)));
        assert_eq!(tiny.size_with_minimum(64, 4096, (144, 128)), None);
    }
    #[test]
    fn different_quality_has_independent_history_and_hidden_stream_is_retired() {
        let p=fixture(1..=10,&[1,8]);
        let small=Stream {pacing:0,codec:Codec::Hevc,quality:Quality {max_height:360,..Quality::default()}};
        assert!(p.next(small,0,0).is_none());
        p.demand(HashSet::new(),HashSet::new(),HashMap::new(),false);
        assert!(p.shared.lock().unwrap().streams.is_empty());
        assert!(p.next(Codec::Hevc.into(),0,0).is_none());
    }
    #[test]
    fn private_pacing_has_independent_history_and_retires_failed_encoders() {
        let p = fixture(1..=10, &[1, 8]);
        let shared = Stream::from(Codec::Hevc);
        let private = Stream {pacing: 7, ..shared};
        assert!(p.next(private, 0, 0).is_none());
        assert!(p.next(shared, 0, 0).is_some());
        p.shared.lock().unwrap().streams.insert(private, Rendition {failed:Some(Instant::now()), ..Default::default()});
        p.retain_pacing(&[7].into_iter().collect());
        assert!(p.shared.lock().unwrap().streams.contains_key(&private));
        p.retain_pacing(&HashSet::new());
        assert!(!p.shared.lock().unwrap().streams.contains_key(&private));
        assert!(p.next(shared, 0, 0).is_some(), "Disconnecting a private viewer preserves shared history");
    }

    #[test]
    fn exhausted_rendition_retries_after_cooldown() {
        if !graffitty_chromium_video::encoders(&Codec::PREFERENCE).contains(&Codec::Hevc) { return; }
        let p = fixture(1..=10, &[1, 8]);
        let stream = Stream::from(Codec::Hevc);
        let now = Instant::now();
        p.shared.lock().unwrap().streams.insert(stream, Rendition {failed:Some(now), ..Default::default()});
        assert!(p.available_at(&[Codec::Hevc], stream.quality, 0, now + Duration::from_secs(4)).is_none());
        assert_eq!(p.available_at(&[Codec::Hevc], stream.quality, 0, now + Duration::from_secs(5)), Some(stream));
        assert!(!p.shared.lock().unwrap().streams.contains_key(&stream), "A retry cannot retain the failed packet history");
    }

    #[test]
    fn failed_preferred_codec_does_not_interrupt_working_fallback() {
        if ![Codec::Hevc, Codec::H264].iter().all(|c| graffitty_chromium_video::encoders(&Codec::PREFERENCE).contains(c)) { return; }
        let p = fixture(1..=10, &[1, 8]);
        let preferred = Stream::from(Codec::Hevc);
        let fallback = Stream::from(Codec::H264);
        let now = Instant::now();
        {
            let mut shared = p.shared.lock().unwrap();
            let packets = shared.streams[&preferred].packets.clone();
            shared.streams.insert(fallback, Rendition {packets, ..Default::default()});
            shared.streams.insert(preferred, Rendition {failed:Some(now), ..Default::default()});
        }
        assert_eq!(p.available_at(&[Codec::Hevc, Codec::H264], preferred.quality, 0, now + Duration::from_secs(60)), Some(fallback));
        assert!(p.shared.lock().unwrap().streams[&preferred].failed.is_some());
        assert!(p.next(fallback, 0, 0).is_some());
    }

    #[test]
    fn hardware_renditions_scale_and_deliver_the_final_frame_after_throttling() {
        let Some(&codec)=graffitty_chromium_video::encoders(&Codec::PREFERENCE).first() else {return;};
        let p=Pipeline::new();
        let small=Stream {pacing:0,codec,quality:Quality {max_height:144,fps:15,bitrate_kbps:1000}};
        let full=Stream {pacing:0,codec,quality:Quality::default()};
        p.demand([small,full].into_iter().collect(),HashSet::new(),HashMap::new(),false);
        let mut png=std::io::Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(512,288,image::Rgba([20,80,160,255])).write_to(&mut png,image::ImageFormat::Png).unwrap();
        let frame=Source::Image(Arc::new(png.into_inner()));
        p.source(1,frame.clone());
        let deadline=Instant::now()+Duration::from_secs(5);
        while p.next(small,0,0).is_none() || p.next(full,0,0).is_none() {assert!(Instant::now()<deadline);thread::sleep(Duration::from_millis(10));}
        let a=p.next(small,0,0).unwrap();let b=p.next(full,0,0).unwrap();
        assert_eq!((a.width,a.height,a.source_width,a.source_height),(256,144,512,288));
        assert_eq!((b.width,b.height),(512,288));
        p.source(2,frame);
        while p.next(small,a.epoch,a.sequence).is_none() {assert!(Instant::now()<deadline);thread::sleep(Duration::from_millis(10));}
    }
    #[test]
    fn paused_renditions_resume_with_the_newest_page_without_a_keyframe() {
        let Some(&codec)=graffitty_chromium_video::encoders(&Codec::PREFERENCE).first() else {return;};
        let p=Pipeline::new();
        let stream=Stream {pacing:0,codec,quality:Quality::default()};
        p.demand([stream].into_iter().collect(),HashSet::new(),HashMap::new(),false);
        let page=|color:u8| {
            let mut png=std::io::Cursor::new(Vec::new());
            image::RgbaImage::from_pixel(256,144,image::Rgba([color,80,160,255])).write_to(&mut png,image::ImageFormat::Png).unwrap();
            Source::Image(Arc::new(png.into_inner()))
        };
        p.source(1,page(20));
        let deadline=Instant::now()+Duration::from_secs(5);
        let mut delivered=vec![loop {
            if let Some(packet)=p.next(stream,0,0) {break packet;}
            assert!(Instant::now()<deadline);thread::sleep(Duration::from_millis(10));
        }];
        // Polling before the first packet requests recovery keyframes, which
        // are encoded even while paused. Deliver those before pausing.
        thread::sleep(Duration::from_millis(200));
        while let Some(packet)=p.next(stream,delivered.last().unwrap().epoch,delivered.last().unwrap().sequence) {delivered.push(packet);}
        let last=delivered.last().unwrap().clone();
        // The client's window is full: page updates must not grow its backlog.
        p.demand([stream].into_iter().collect(),[stream].into_iter().collect(),HashMap::new(),false);
        for revision in 2..=6 {p.source(revision,page(20+revision as u8*30));thread::sleep(Duration::from_millis(40));}
        assert!(p.next(stream,last.epoch,last.sequence).is_none(), "A paused rendition encodes nothing");
        p.demand([stream].into_iter().collect(),HashSet::new(),HashMap::new(),false);
        let resumed=loop {
            if let Some(packet)=p.next(stream,last.epoch,last.sequence) {break packet;}
            assert!(Instant::now()<deadline);thread::sleep(Duration::from_millis(10));
        };
        assert_eq!((resumed.epoch,resumed.sequence),(last.epoch,last.sequence+1));
        assert!(!resumed.key, "Resuming continues the reference chain");
        let mut decoder=graffitty_chromium_video::Decoder::new(codec).unwrap();
        for packet in &delivered {decoder.decode(&packet.bytes).unwrap();}
        let frame=decoder.decode(&resumed.bytes).unwrap().expect("The resumed frame decodes");
        assert!((frame.rgba[0] as i16-200).abs()<24, "The resumed frame shows the newest page, not a skipped one");
    }
    #[test]
    fn a_new_bitrate_continues_the_stream_without_a_keyframe() {
        let Some(&codec)=graffitty_chromium_video::encoders(&Codec::PREFERENCE).first() else {return;};
        let p=Pipeline::new();
        let stream=Stream {pacing:0,codec,quality:Quality {bitrate_kbps:6000,fps:60,max_height:144}};
        let page=|color:u8| {
            let mut png=std::io::Cursor::new(Vec::new());
            image::RgbaImage::from_pixel(256,144,image::Rgba([color,80,160,255])).write_to(&mut png,image::ImageFormat::Png).unwrap();
            Source::Image(Arc::new(png.into_inner()))
        };
        p.demand([stream].into_iter().collect(),HashSet::new(),HashMap::new(),false);
        p.source(1,page(20));
        let deadline=Instant::now()+Duration::from_secs(5);
        let first=loop {
            if let Some(packet)=p.next(stream,0,0) {break packet;}
            assert!(Instant::now()<deadline);thread::sleep(Duration::from_millis(10));
        };
        thread::sleep(Duration::from_millis(200));
        let mut last=first;
        while let Some(packet)=p.next(stream,last.epoch,last.sequence) {last=packet;}
        // The viewer's link lowered its bitrate tier.
        p.demand([stream].into_iter().collect(),HashSet::new(),[(stream,0.5)].into_iter().collect(),false);
        p.source(2,page(120));
        let next=loop {
            if let Some(packet)=p.next(stream,last.epoch,last.sequence) {break packet;}
            assert!(Instant::now()<deadline);thread::sleep(Duration::from_millis(10));
        };
        assert_eq!((next.epoch,next.sequence),(last.epoch,last.sequence+1), "The viewer's decoder continues the same stream");
        assert!(!next.key, "A live rate change needs no keyframe");
    }
    fn fixture(sequences: std::ops::RangeInclusive<u64>, keys: &[u64]) -> Pipeline {
        let pipeline = Pipeline::new();
        let packets = sequences
            .map(|sequence| Packet {
                sequence,
                epoch: 7,
                width: 1000,
                height: 700, source_width:1000, source_height:700,
                key: keys.contains(&sequence),
                bytes: Arc::new(vec![1, 2, 3]),
            })
            .collect();
        pipeline.shared.lock().unwrap().streams.insert(
            Codec::Hevc.into(),
            Rendition {
                packets,
                failed: None,
                bytes: 0,
            },
        );
        pipeline
    }
    #[test]
    fn joins_and_epoch_changes_start_at_latest_keyframe() {
        let p = fixture(1..=10, &[1, 8]);
        assert_eq!(p.next(Codec::Hevc.into(), 0, 0).unwrap().sequence, 8);
        assert_eq!(p.next(Codec::Hevc.into(), 6, 999).unwrap().sequence, 8);
        assert_eq!(p.next(Codec::Hevc.into(), 7, 8).unwrap().sequence, 9);
        assert!(p.next(Codec::Hevc.into(), 7, 10).is_none());
    }
    #[test]
    fn slow_client_skips_only_to_keyframe() {
        let p = fixture(1..=20, &[1, 18]);
        let recovered = p.next(Codec::Hevc.into(), 7, 2).unwrap();
        assert!(recovered.key);
        assert_eq!(recovered.sequence, 18);
    }
    #[test]
    fn late_join_requests_fresh_key_instead_of_displaying_old_page() {
        let p = fixture(1..=50, &[1]);
        assert!(p.next(Codec::Hevc.into(), 0, 0).is_none());
        assert!(p.shared.lock().unwrap().keyframes.contains(&Codec::Hevc.into()));
    }
    #[test]
    fn a_pending_first_keyframe_is_not_requested_twice() {
        let p = Pipeline::new();
        p.shared.lock().unwrap().streams.insert(Codec::Hevc.into(), Rendition::default());
        assert!(p.next(Codec::Hevc.into(), 0, 0).is_none());
        assert!(!p.shared.lock().unwrap().keyframes.contains(&Codec::Hevc.into()),
            "A forced second keyframe would bypass a paused rendition");
    }
    #[test]
    fn missing_references_request_keyframe_instead_of_sending_corruption() {
        let p = fixture(10..=20, &[]);
        assert!(p.next(Codec::Hevc.into(), 7, 2).is_none());
        assert!(p.shared.lock().unwrap().keyframes.contains(&Codec::Hevc.into()));
    }
}
