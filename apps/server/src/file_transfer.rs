//! Terminal attachment staging, adapted from herdr-core's put.rs (Apache-2.0).
//! Graffitty uses acknowledged chunks, private staging and atomic publication.
//! See NOTICE for the upstream revision and attribution.
use crate::{Error, api};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use graffitty_protocol::file_transfer::{CHUNK_BYTES, Chunk, MAX_BYTES, Receipt};
use std::{collections::HashMap, fs, io::Write, path::{Path, PathBuf}, time::{Duration, Instant}};

const TIMEOUT: Duration = Duration::from_secs(120);
struct Pending {
    file: fs::File,
    directory: PathBuf,
    name: String,
    size: usize,
    received: usize,
    paste: bool,
    touched: Instant,
}
#[derive(Default)]
pub struct Store { pending: HashMap<(u64, String), Pending> }

// Adapted from herdr-core::put::clean: basename only, portable and non-executable
// as terminal input. Quoting below also protects spaces in the parent directory.
fn clean(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let safe: String = base.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '_' }).collect();
    let safe = safe.trim_start_matches('.');
    if safe.is_empty() { "file".into() } else { safe.into() }
}

impl Store {
    pub fn expire(&mut self) {
        let expired: Vec<_> = self.pending.iter().filter(|(_, p)| p.touched.elapsed() >= TIMEOUT).map(|(key, _)| key.clone()).collect();
        for key in expired {
            let pending = self.pending.remove(&key).unwrap();
            drop(pending.file);
            let _ = fs::remove_dir_all(pending.directory);
        }
    }
    pub fn remove(&mut self, root: &Path, pane: u64) {
        self.pending.retain(|(id, _), _| *id != pane);
        let _ = fs::remove_dir_all(root.join(pane.to_string()));
    }
    pub fn receive(&mut self, root: &Path, pane: u64, chunk: Chunk) -> Result<(Receipt, bool), Error> {
        self.expire();
        let invalid = || api::error("invalid_params", "Invalid file upload chunk");
        if uuid::Uuid::parse_str(&chunk.id).is_err() || chunk.id.len() != 36
            || chunk.name.is_empty() || chunk.name.len() > 255 || chunk.name.chars().any(char::is_control)
            || chunk.size > MAX_BYTES || chunk.data.len() > CHUNK_BYTES.div_ceil(3) * 4 {
            return Err(invalid());
        }
        let data = STANDARD.decode(&chunk.data).map_err(|_| invalid())?;
        let end = chunk.offset.checked_add(data.len()).ok_or_else(invalid)?;
        if data.len() > CHUNK_BYTES || end > chunk.size || (data.is_empty() && chunk.size != 0) { return Err(invalid()); }
        let key = (pane, chunk.id.clone());
        if !self.pending.contains_key(&key) {
            if chunk.offset != 0 { return Err(api::error("upload_expired", "Upload expired or belongs to another terminal")); }
            if self.pending.len() >= 64 || self.pending.keys().filter(|(id, _)| *id == pane).count() >= 4 {
                return Err(api::error("busy", "Too many incomplete file uploads"));
            }
            let parent = root.join(pane.to_string());
            private_directory(&parent)?;
            let directory = parent.join(&chunk.id);
            // create_dir (not create_dir_all) also rejects replay of a completed
            // transfer, including an empty file or lost final acknowledgment.
            fs::create_dir(&directory)?;
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
            let file = options.open(directory.join(".part"))?;
            self.pending.insert(key.clone(), Pending { file, directory, name: chunk.name.clone(),
                size: chunk.size, received: 0, paste: chunk.paste, touched: Instant::now() });
        }
        let pending = self.pending.get_mut(&key).unwrap();
        if pending.received != chunk.offset || pending.name != chunk.name || pending.size != chunk.size || pending.paste != chunk.paste {
            return Err(invalid());
        }
        pending.file.write_all(&data)?;
        pending.received = end;
        pending.touched = Instant::now();
        let mut receipt = Receipt { id: chunk.id, pane: format!("%{pane}"), received: end, path: None };
        if end != chunk.size { return Ok((receipt, false)); }
        let pending = self.pending.remove(&key).unwrap();
        pending.file.sync_all()?;
        drop(pending.file);
        let path = pending.directory.join(clean(&pending.name));
        fs::rename(pending.directory.join(".part"), &path)?;
        receipt.path = Some(path.to_string_lossy().into_owned());
        Ok((receipt, pending.paste))
    }
}

fn private_directory(path: &Path) -> Result<(), Error> {
    fs::create_dir_all(path)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)] graffitty_session_transport::local_json::restrict_directory(path)?;
    Ok(())
}

pub fn quoted_path(path: &str) -> String {
    // Codex/Claude recognize a quoted dropped-file path as an attachment.
    // No newline/Enter is generated. PowerShell and POSIX both quote with '.
    #[cfg(windows)] { format!("'{}'", path.replace('\'', "''")) }
    #[cfg(not(windows))] { format!("'{}'", path.replace('\'', "'\\''")) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn publish_once_after_all_chunks_and_keep_original_bytes() {
        let root = std::env::temp_dir().join(format!("gft-put-test-{}", uuid::Uuid::new_v4()));
        let mut store = Store::default();
        let chunk = Chunk { id: uuid::Uuid::new_v4().to_string(), name: "../../image.png".into(), size: 4, offset: 0, data: STANDARD.encode([0, 255]), paste: true };
        let (receipt, paste) = store.receive(&root, 7, chunk.clone()).unwrap();
        assert!(receipt.path.is_none() && !paste);
        assert!(store.receive(&root, 7, chunk.clone()).is_err());
        let last = Chunk { offset: 2, data: STANDARD.encode([13, 10]), ..chunk.clone() };
        assert!(store.receive(&root, 8, last.clone()).is_err());
        assert!(store.receive(&root, 7, Chunk { name: "changed.png".into(), ..last.clone() }).is_err());
        let (receipt, paste) = store.receive(&root, 7, last.clone()).unwrap();
        let path = PathBuf::from(receipt.path.unwrap());
        assert_eq!(path.file_name().unwrap(), "image.png");
        assert_eq!(fs::read(&path).unwrap(), [0, 255, 13, 10]);
        assert!(paste);
        assert!(store.receive(&root, 7, last).is_err());
        assert!(store.receive(&root, 7, chunk).is_err());
        store.remove(&root, 7);
        assert!(!path.exists());
        let _ = fs::remove_dir_all(root);
    }
    #[test]
    fn reject_oversize_traversal_and_expire_partial_uploads() {
        let root = std::env::temp_dir().join(format!("gft-put-test-{}", uuid::Uuid::new_v4()));
        let mut store = Store::default();
        let chunk = Chunk { id: uuid::Uuid::new_v4().to_string(), name: "shot.png".into(), size: 2, offset: 0, data: STANDARD.encode([0]), paste: false };
        for invalid in [Chunk { id: "../escape".into(), ..chunk.clone() }, Chunk { size: MAX_BYTES+1, ..chunk.clone() }, Chunk { name: "bad\nname".into(), ..chunk.clone() }, Chunk { offset: usize::MAX, ..chunk.clone() }] {
            assert!(store.receive(&root, 7, invalid).is_err());
        }
        store.receive(&root, 7, chunk.clone()).unwrap();
        store.pending.values_mut().next().unwrap().touched -= TIMEOUT;
        store.expire();
        assert!(store.pending.is_empty());
        assert!(!root.join("7").join(&chunk.id).exists());
        let _ = fs::remove_dir_all(root);
    }
}
