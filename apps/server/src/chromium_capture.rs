//! Desktop CEF control uses a private Unix socket. GPU frames use Mach ports on
//! macOS. On Linux a private SOCK_SEQPACKET endpoint negotiates Vulkan or
//! sealed software frames. Chrome software screencasts use the control socket.
use graffitty_chromium_video::surface::Receiver;
use std::{
    fs,
    os::unix::{
        fs::PermissionsExt,
        net::UnixListener,
    },
    path::{Path, PathBuf},
    process::Child,
    thread,
    time::{Duration, Instant},
};
pub use crate::chromium_control::Control;

pub fn executable() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = std::env::var_os("GRAFFITTY_CHROMIUM_HOST") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
        return Err("GRAFFITTY_CHROMIUM_HOST does not point to a chromium host".into());
    }
    let current = std::env::current_dir()?;
    let mut roots: Vec<PathBuf> = current.ancestors().take(5).map(Path::to_path_buf).collect();
    if let Ok(exe) = std::env::current_exe() {
        for parent in exe.ancestors().skip(1).take(5) {
            roots.push(parent.into());
        }
    }
    // A source build can be frozen outside the checkout for isolated tests.
    // Installed bundles above remain the first choice; the build-time checkout
    // is only a development fallback when its explicit host pointer exists.
    roots.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));
    for root in roots {
        for directory in [root.join("dist"), root.clone()] {
            if let Ok(relative) = fs::read_to_string(directory.join("chromium-host-path.txt")) {
                let path = directory.join(relative.trim());
                if path.is_file() {
                    return Ok(path);
                }
            }
            let path = directory.join("Chromium GPU Host.app/Contents/MacOS/probe");
            if cfg!(target_os = "macos") && path.is_file() {
                return Ok(path);
            }
        }
    }
    let script = if cfg!(target_os = "macos") { "build.sh" } else { "build-linux.sh" };
    Err(format!(
        "GPU chromium host missing: build apps/server/chromium/{script} or set GRAFFITTY_CHROMIUM_HOST"
    )
    .into())
}
pub struct Capture {
    pub(crate) listener: UnixListener,
    pub receiver: Receiver,
    pub endpoint: String,
    pub control: PathBuf,
    pub artifacts: PathBuf,
    pub(crate) control_directory: PathBuf,
    pub(crate) keep_control_directory: bool,
}
impl Capture {
    pub fn new(directory: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let endpoint = format!("dev.graffitty.server.{}", uuid::Uuid::new_v4().simple());
        let receiver = Receiver::new(&endpoint)?;
        // Keep the socket path below macOS's 104-byte sockaddr_un limit, even
        // when a persistent chromium profile has a long path.
        let control_directory =
            std::env::temp_dir().join(format!("gr-cap-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir(&control_directory)?;
        fs::set_permissions(&control_directory, fs::Permissions::from_mode(0o700))?;
        let control = control_directory.join("control");
        let listener = UnixListener::bind(&control)?;
        listener.set_nonblocking(true)?;
        Ok(Self {
            listener,
            receiver,
            endpoint,
            control,
            artifacts: directory.to_path_buf(),
            control_directory,
            keep_control_directory: false,
        })
    }
    pub fn accept(&self, child: &mut Child) -> Result<Control, Box<dyn std::error::Error>> {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match self.listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(true)?;
                    return Ok(Control::new(stream)?);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e.into()),
            }
            if child.try_wait()?.is_some() || Instant::now() > deadline {
                return Err("GPU chromium host failed to start".into());
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for Capture {
    fn drop(&mut self) {
        if !self.keep_control_directory {
            let _ = fs::remove_dir_all(&self.control_directory);
        }
    }
}
