//! Private CEF control bound to the actual chromium process, not a TCP port.
pub use crate::chromium_control::Control;
use graffitty_session_transport::{self as ipc, ControlStream};
use std::{
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};
use terminal_resource_monitor::windows::Process;

pub fn executable() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = std::env::var_os("GRAFFITTY_CHROMIUM_HOST") {
        let path = PathBuf::from(path).canonicalize()?;
        if path.is_file() {
            return Ok(path);
        }
        return Err("GRAFFITTY_CHROMIUM_HOST is not a file".into());
    }
    let mut roots = Vec::new();
    for path in [
        std::env::current_exe()?,
        PathBuf::from(env!("CARGO_MANIFEST_DIR")),
    ] {
        roots.extend(path.ancestors().take(6).map(Path::to_path_buf));
    }
    for root in roots {
        for relative in [
            "chromium-windows/graffitty_chromium.exe",
            "dist/chromium-windows/graffitty_chromium.exe",
        ] {
            let path = root.join(relative);
            if path.is_file() {
                return Ok(path.canonicalize()?);
            }
        }
    }
    Err("Build apps/server/chromium/build-windows.ps1 or set GRAFFITTY_CHROMIUM_HOST".into())
}

pub struct Capture {
    listener: ipc::Listener,
    pub receiver: graffitty_chromium_video::surface::Receiver,
    pub endpoint: String,
    pub control: PathBuf,
    pub artifacts: PathBuf,
}
impl Capture {
    pub fn new(directory: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let control = PathBuf::from(format!(
            r"\\.\pipe\graffitty-chromium-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let endpoint = format!("graffitty-capture-{}", uuid::Uuid::new_v4().simple());
        let receiver = graffitty_chromium_video::surface::Receiver::new(&endpoint)?;
        Ok(Self {
            receiver,
            endpoint,
            listener: ipc::bind(&control)?,
            control,
            artifacts: directory.to_path_buf(),
        })
    }
    pub fn accept(&self, child: &mut Process) -> Result<Control, Box<dyn std::error::Error>> {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match ControlStream::accept(&self.listener) {
                Ok(stream) => {
                    if stream.client_process_id()? != child.id() {
                        return Err("CEF control peer does not match the launched process".into());
                    }
                    return Ok(Control::new(stream)?);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.into()),
            }
            if child.try_wait()?.is_some() || Instant::now() >= deadline {
                return Err("CEF host did not connect its private control pipe".into());
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}
