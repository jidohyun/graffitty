//! Save the state the next server needs to adopt terminals kept alive by
//! the holder.
//!
//! - Owner epoch and IPC endpoint, as named by the programs' environment.
//! - Each session's capability, placement, and pins.
//! - Live filetree associations and RPC addresses.
//!
//! A planned restart saves every screen exactly. After a crash, the next
//! server rebuilds screens from the holder's recent output.
//!
//! The role of herdr-core's terminal registry and screen snapshots
//! (`runtime/persistence.rs`, `Core::handover`), reduced to Graffitty's sessions.
use crate::Error;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const VERSION: u32 = 1;

#[derive(Serialize, Deserialize, Clone, PartialEq)]
pub struct OwnerState {
    pub version: u32,
    pub epoch: String,
    /// The private runtime directory holding the IPC endpoint.
    pub runtime: PathBuf,
    pub next: u64,
    pub tab_titles: HashMap<u64, String>,
    pub sessions: Vec<SavedSession>,
    pub workspaces: crate::session_registry::Registry,
    /// Optional application metadata; terminals can exist without any filetrees.
    #[serde(default)]
    pub filetrees: crate::filetree::SavedFiletrees,
    /// The session a frontend showed last, which a starting frontend resumes.
    #[serde(default)]
    pub last_viewed: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq)]
pub struct SavedSession {
    pub id: u64,
    pub tab: u64,
    pub workspace: String,
    pub shell: String,
    pub token: String,
    pub pinned_title: String,
    pub builtin_title: String,
    pub font_size: u16,
    pub rect: [f64; 4],
    pub logical_extent: (f64, f64),
    pub layout_extent: Option<(f64, f64)>,
    pub limits: crate::spawn::TerminalLimits,
    pub initial_directory: Option<PathBuf>,
    pub home_directory: Option<PathBuf>,
    pub program_status: graffitty_terminal_core::program_status::ProgramStatus,
    /// The pane that ran `gft pane run` to create this one, as herdr's parent.
    #[serde(default)]
    pub spawned_by: Option<u64>,
    #[serde(default)]
    pub dies_with_parent: bool,
    /// Windows: the title the console starts with. A program did not set it.
    #[serde(default)]
    pub console_title: String,
}

pub fn path(descriptor: &Path) -> PathBuf {
    descriptor.with_extension("owner.json")
}

fn screens(descriptor: &Path) -> PathBuf {
    descriptor.with_extension("screens")
}

fn screen(descriptor: &Path, id: u64) -> PathBuf {
    screens(descriptor).join(format!("{id}.vt"))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    use std::io::Write;
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(temporary, path)?;
    Ok(())
}

pub fn save(descriptor: &Path, state: &OwnerState) -> Result<(), Error> {
    write_atomic(&path(descriptor), &serde_json::to_vec(state)?)
}

/// Saves the record an installer needs to start a parked server again:
/// its command line, the number of terminals its holders keep, and the
/// frontends that were told to close.
pub fn save_parked(descriptor: &Path, parked: &serde_json::Value) -> Result<(), Error> {
    write_atomic(&descriptor.with_extension("update.json"), &serde_json::to_vec(parked)?)
}

/// A planned restart: each screen exactly, as VT that rebuilds it.
pub fn save_screen(descriptor: &Path, id: u64, vt: &[u8]) -> Result<(), Error> {
    let dir = screens(descriptor);
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&dir)?;
    write_atomic(&screen(descriptor, id), vt)
}

/// The previous owner's state; a missing, unreadable or other-version file is
/// no state (its terminals can't be addressed and are ended).
pub fn load(descriptor: &Path) -> Option<OwnerState> {
    let bytes = std::fs::read(path(descriptor)).ok()?;
    serde_json::from_slice::<OwnerState>(&bytes).ok().filter(|state| state.version == VERSION && state.workspaces.validate().is_ok())
}

/// Takes a saved screen: each is used once, by the server that adopts it.
pub fn take_screen(descriptor: &Path, id: u64) -> Option<Vec<u8>> {
    let path = screen(descriptor, id);
    let bytes = std::fs::read(&path).ok();
    let _ = std::fs::remove_file(path);
    bytes
}

/// Nothing left to adopt: a stopped owner removes its state and screens.
pub fn clear(descriptor: &Path) {
    let _ = std::fs::remove_file(path(descriptor));
    let _ = std::fs::remove_dir_all(screens(descriptor));
}

impl OwnerState {
    pub fn new(epoch: &str, runtime: &Path, next: u64, tab_titles: &HashMap<u64, String>) -> Self {
        Self {
            version: VERSION,
            epoch: epoch.into(),
            runtime: runtime.into(),
            next,
            tab_titles: tab_titles.clone(),
            sessions: Vec::new(),
            workspaces: Default::default(),
            filetrees: Default::default(),
            last_viewed: None,
        }
    }
}
