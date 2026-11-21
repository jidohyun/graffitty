//! Movie Maker -> raw RGB pipe -> FFmpeg/SVT-AV1. Recordings are silent.
//! Publish the requested MP4 only after FFmpeg has finalized it successfully.
use godot::classes::audio_server::SpeakerMode;
use godot::classes::image::Format;
use godot::classes::{Engine, IMovieWriter, Image, MovieWriter, ProjectSettings};
use godot::global::Error;
use godot::meta::conv::RawPtr;
use godot::prelude::*;
use std::ffi::c_void;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

static ACTIVE: AtomicBool = AtomicBool::new(false);

/// True for an actual Movie Maker session, including its off-camera setup.
/// Rendering can use virtual foreground focus without activating an OS window.
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

/// Godot does not ignore SIGPIPE like a Rust executable does. Block it only
/// around this pipe write, consume our pending signal, then restore the host's mask.
#[cfg(unix)]
fn write_frame(pipe: &mut impl Write, bytes: &[u8]) -> std::io::Result<()> {
    unsafe {
        let mut blocked = std::mem::zeroed();
        let mut previous = std::mem::zeroed();
        let mut pending = std::mem::zeroed();
        libc::sigemptyset(&mut blocked);
        libc::sigaddset(&mut blocked, libc::SIGPIPE);
        let error = libc::pthread_sigmask(libc::SIG_BLOCK, &blocked, &mut previous);
        if error != 0 {
            return Err(std::io::Error::from_raw_os_error(error));
        }
        libc::sigpending(&mut pending);
        let was_pending = libc::sigismember(&pending, libc::SIGPIPE) == 1;
        let result = pipe.write_all(bytes);
        if !was_pending
            && result
                .as_ref()
                .is_err_and(|e| e.raw_os_error() == Some(libc::EPIPE))
        {
            libc::sigpending(&mut pending);
            if libc::sigismember(&pending, libc::SIGPIPE) == 1 {
                let mut signal = 0;
                libc::sigwait(&blocked, &mut signal);
            }
        }
        libc::pthread_sigmask(libc::SIG_SETMASK, &previous, std::ptr::null_mut());
        result
    }
}

#[cfg(not(unix))]
fn write_frame(pipe: &mut impl Write, bytes: &[u8]) -> std::io::Result<()> {
    pipe.write_all(bytes)
}

#[derive(GodotClass)]
#[class(base=MovieWriter)]
pub struct Av1MovieWriter {
    base: Base<MovieWriter>,
    child: Option<Child>,
    output: PathBuf,
    partial: PathBuf,
    size: Vector2i,
    frames: u64,
    paused: bool,
    failed: bool,
}

pub fn register() {
    let writer = Av1MovieWriter::new_alloc();
    MovieWriter::add_writer(&writer);
    Engine::singleton().register_singleton("GraffittyMovieWriter", &writer);
}

pub fn unregister() {
    let mut engine = Engine::singleton();
    if let Some(writer) = engine.get_singleton("GraffittyMovieWriter") {
        engine.unregister_singleton("GraffittyMovieWriter");
        writer.free();
    }
}

#[godot_api]
impl Av1MovieWriter {
    /// Effects capture skips shell startup; replay captures start immediately.
    #[func]
    fn set_recording(&mut self, enabled: bool) {
        self.paused = !enabled;
    }

    #[func]
    fn frames_written(&self) -> i64 {
        self.frames as i64
    }
}

#[godot_api]
impl IMovieWriter for Av1MovieWriter {
    fn init(base: Base<MovieWriter>) -> Self {
        Self {
            base,
            child: None,
            output: PathBuf::new(),
            partial: PathBuf::new(),
            size: Vector2i::ZERO,
            frames: 0,
            paused: false,
            failed: false,
        }
    }
    fn get_audio_mix_rate(&self) -> u32 {
        48000
    }
    fn get_audio_speaker_mode(&self) -> SpeakerMode {
        SpeakerMode::STEREO
    }
    fn handles_file(&self, path: GString) -> bool {
        path.to_string().to_lowercase().ends_with(".mp4")
    }
    fn get_supported_extensions(&self) -> PackedStringArray {
        PackedStringArray::from(&[GString::from("mp4")])
    }
    fn write_begin(&mut self, movie_size: Vector2i, fps: u32, base_path: GString) -> Error {
        ACTIVE.store(false, Ordering::Relaxed);
        self.size = movie_size;
        self.frames = 0;
        self.failed = false;
        self.paused = std::env::var("GRAFFITTY_MOVIE_PAUSED").as_deref() == Ok("1");
        self.output = PathBuf::from(
            ProjectSettings::singleton()
                .globalize_path(&base_path)
                .to_string(),
        );
        self.partial = self
            .output
            .with_extension(format!("{}.partial.mp4", std::process::id()));
        let ffmpeg = std::env::var_os("GRAFFITTY_FFMPEG").unwrap_or_else(|| "ffmpeg".into());
        let crf = std::env::var("GRAFFITTY_AV1_CRF").unwrap_or_else(|_| "24".into());
        let preset = std::env::var("GRAFFITTY_AV1_PRESET").unwrap_or_else(|_| "8".into());
        let result = Command::new(ffmpeg)
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-y",
                "-f",
                "rawvideo",
                "-pixel_format",
                "rgb24",
                "-video_size",
                &format!("{}x{}", movie_size.x, movie_size.y),
                "-framerate",
                &fps.to_string(),
                "-i",
                "pipe:0",
                "-an",
                "-vf",
                "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                "-c:v",
                "libsvtav1",
                "-preset",
                &preset,
                "-crf",
                &crf,
                "-svtav1-params",
                "lp=4",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
            ])
            .arg(&self.partial)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn();
        match result {
            Ok(child) => {
                // Darwin may deliver a pipe signal to another engine thread;
                // suppress it on this descriptor rather than changing Godot's
                // process-wide signal disposition.
                #[cfg(target_os = "macos")]
                if let Some(pipe) = child.stdin.as_ref() {
                    use std::os::fd::AsRawFd;
                    const F_SETNOSIGPIPE: libc::c_int = 73; // Darwin <sys/fcntl.h>
                    if unsafe { libc::fcntl(pipe.as_raw_fd(), F_SETNOSIGPIPE, 1) } == -1 {
                        self.child = Some(child);
                        self.failed = true;
                        godot_error!("AV1 MovieWriter: cannot protect encoder pipe: {}", std::io::Error::last_os_error());
                        return Error::ERR_CANT_CREATE;
                    }
                }
                self.child = Some(child);
                ACTIVE.store(true, Ordering::Relaxed);
                Error::OK
            }
            Err(err) => {
                godot_error!("AV1 MovieWriter: cannot start FFmpeg: {err}");
                self.failed = true;
                Error::ERR_CANT_CREATE
            }
        }
    }
    unsafe fn write_frame_rawptr(
        &mut self,
        frame_image: Option<Gd<Image>>,
        _audio: RawPtr<*const c_void>,
    ) -> Error {
        if self.failed {
            return Error::ERR_FILE_CANT_WRITE;
        }
        if self.paused {
            return Error::OK;
        }
        let Some(mut image) = frame_image else {
            return Error::ERR_INVALID_DATA;
        };
        // Movie Maker's output dimensions are fixed for the lifetime of the pipe.
        // Resizing the physical window must not change rawvideo frame boundaries.
        if image.get_size() != self.size {
            image.resize(self.size.x, self.size.y);
        }
        image.convert(Format::RGB8);
        let data = image.get_data();
        let result = self
            .child
            .as_mut()
            .and_then(|c| c.stdin.as_mut())
            .ok_or_else(|| std::io::Error::other("encoder is not running"))
            .and_then(|pipe| write_frame(pipe, data.as_slice()));
        match result {
            Ok(()) => {
                self.frames += 1;
                Error::OK
            }
            Err(err) => {
                self.failed = true;
                godot_error!("AV1 MovieWriter: frame write failed: {err}");
                Error::ERR_FILE_CANT_WRITE
            }
        }
    }
    fn write_end(&mut self) {
        ACTIVE.store(false, Ordering::Relaxed);
        let Some(mut child) = self.child.take() else {
            return;
        };
        drop(child.stdin.take()); // EOF flushes the encoder and MP4 index.
        let success = child.wait().map(|s| s.success()).unwrap_or(false);
        if success && !self.failed && self.frames > 0 {
            if let Err(err) = std::fs::rename(&self.partial, &self.output) {
                godot_error!(
                    "AV1 MovieWriter: cannot publish {}: {err}",
                    self.output.display()
                );
                return;
            }
            godot_print!(
                "AV1_MOVIE_PASS frames={} path={}",
                self.frames,
                self.output.display()
            );
        } else {
            self.failed = true;
            let _ = std::fs::remove_file(&self.partial);
            godot_error!("AV1 MovieWriter: encoder failed or no frames were recorded");
        }
    }
}
impl Drop for Av1MovieWriter {
    fn drop(&mut self) {
        ACTIVE.store(false, Ordering::Relaxed);
        if let Some(mut child) = self.child.take() {
            drop(child.stdin.take());
            let _ = child.kill();
            let _ = child.wait();
            let _ = std::fs::remove_file(&self.partial);
        }
    }
}
