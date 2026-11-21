//! Content-addressed font files. Godot owns UI/requests; Rust owns validation and IO.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct FontHash(String);
impl FontHash {
    pub fn parse(s: &str) -> Result<Self> {
        ensure!(
            s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()),
            "Invalid font hash"
        );
        Ok(Self(s.to_ascii_lowercase()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Stamp {
    size: u64,
    modified_ns: u128,
    digest: FontHash,
}
#[derive(Default)]
pub struct FontCache {
    directory: PathBuf,
    hashes: BTreeMap<PathBuf, Stamp>,
}
#[derive(Default, Serialize)]
pub struct CacheStats {
    pub bytes: u64,
    pub files: u64,
}
impl FontCache {
    pub fn new(directory: PathBuf) -> Self {
        let hashes = fs::read(directory.join("hashes.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Self { directory, hashes }
    }
    fn stamp(path: &Path, digest: FontHash) -> Result<Stamp> {
        let m = fs::metadata(path)?;
        Ok(Stamp {
            size: m.len(),
            modified_ns: m.modified()?.duration_since(UNIX_EPOCH)?.as_nanos(),
            digest,
        })
    }
    fn save(&mut self) -> Result<()> {
        self.hashes.retain(|p, _| p.is_file());
        fs::create_dir_all(&self.directory)?;
        let mut temp = tempfile::NamedTempFile::new_in(&self.directory)?;
        serde_json::to_writer(&mut temp, &self.hashes)?;
        temp.flush()?;
        temp.persist(self.directory.join("hashes.json"))?;
        Ok(())
    }
    pub fn hash(&mut self, path: &Path) -> Result<FontHash> {
        let m = fs::metadata(path)?;
        let stamp = m.modified()?.duration_since(UNIX_EPOCH)?.as_nanos();
        if let Some(known) = self
            .hashes
            .get(path)
            .filter(|h| h.size == m.len() && h.modified_ns == stamp)
        {
            return Ok(known.digest.clone());
        }
        let digest = Self::digest(path)?;
        let _ = self.remember(path, digest.clone());
        Ok(digest)
    }
    pub fn digest(path: &Path) -> Result<FontHash> {
        let mut file = File::open(path)?;
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 65536];
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
        }
        Ok(FontHash(hash.finalize().iter().map(|byte| format!("{byte:02x}")).collect()))
    }
    pub fn remember(&mut self, path: &Path, digest: FontHash) -> Result<()> {
        self.hashes.insert(path.into(), Self::stamp(path, digest)?);
        self.save()
    }
    pub fn length(path: &Path) -> u64 {
        fs::metadata(path).map(|m| m.len()).unwrap_or(0)
    }
    pub fn partial(&self, hash: &FontHash) -> PathBuf {
        self.directory.join(format!(
            "{}.font.{}.part",
            hash.as_str(),
            std::process::id()
        ))
    }
    pub fn path(&self, hash: &FontHash) -> PathBuf {
        self.directory.join(format!("{}.font", hash.as_str()))
    }
    pub fn begin(&self, hash: &FontHash, length: u64, mobile: bool) -> Result<u64> {
        ensure!(length > 0 && length <= 67108864, "Invalid font length");
        fs::create_dir_all(&self.directory)?;
        let partial = self.partial(hash);
        self.adopt_partial(
            &self.path(hash),
            &partial,
            if mobile {
                Duration::ZERO
            } else {
                Duration::from_secs(120)
            },
        )?;
        let offset = Self::length(&partial);
        if offset > length {
            fs::remove_file(partial)?;
            Ok(0)
        } else {
            Ok(offset)
        }
    }
    pub fn append(&self, hash: &FontHash, length: u64, offset: u64, data: &[u8]) -> Result<u64> {
        ensure!(
            length > 0
                && length <= 67108864
                && !data.is_empty()
                && offset
                    .checked_add(data.len() as u64)
                    .is_some_and(|end| end <= length),
            "Invalid font chunk"
        );
        let path = self.partial(hash);
        ensure!(Self::length(&path) == offset, "Font chunk offset mismatch");
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(offset == 0)
            .open(path)?;
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(data)?;
        file.flush()?;
        Ok(offset + data.len() as u64)
    }
    pub fn finish(&mut self, hash: &FontHash, length: u64) -> Result<PathBuf> {
        let temporary = self.partial(hash);
        ensure!(
            Self::length(&temporary) == length,
            "Incomplete font download"
        );
        if Self::digest(&temporary)? != *hash {
            fs::remove_file(&temporary)?;
            anyhow::bail!("Server font hash mismatch");
        }
        let path = self.path(hash);
        fs::rename(&temporary, &path).context("Cannot commit server font cache")?;
        let _ = self.remember(&path, hash.clone());
        Ok(path)
    }
    pub fn adopt_partial(&self, path: &Path, temporary: &Path, idle: Duration) -> Result<()> {
        if temporary.exists() {
            return Ok(());
        }
        let Some(parent) = path.parent() else {
            return Ok(());
        };
        if !parent.exists() {
            return Ok(());
        }
        let prefix = format!(
            "{}.",
            path.file_name()
                .context("Missing font filename")?
                .to_string_lossy()
        );
        let mut adopted: Option<PathBuf> = None;
        for entry in fs::read_dir(parent)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let metadata = entry.metadata()?;
            if entry.file_type()?.is_symlink()
                || !metadata.is_file()
                || !name.starts_with(&prefix)
                || !name.ends_with(".part")
                || SystemTime::now()
                    .duration_since(metadata.modified()?)
                    .unwrap_or_default()
                    < idle
            {
                continue;
            }
            let candidate = entry.path();
            if adopted
                .as_ref()
                .is_none_or(|old| Self::length(&candidate) > Self::length(old))
            {
                if let Some(old) = adopted.replace(candidate) {
                    fs::remove_file(old)?;
                }
            } else {
                fs::remove_file(candidate)?;
            }
        }
        if let Some(adopted) = adopted {
            fs::rename(adopted, temporary)?;
        }
        Ok(())
    }
    pub fn files(&self) -> Result<Vec<PathBuf>> {
        if !self.directory.exists() {
            return Ok(vec![]);
        }
        let mut result = vec![];
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.len() >= 69
                && name.is_char_boundary(64)
                && FontHash::parse(&name[..64]).is_ok()
                && [".font", ".part", ".tmp"]
                    .iter()
                    .any(|suffix| name.ends_with(suffix))
            {
                result.push(entry.path());
            }
        }
        Ok(result)
    }
    pub fn stats(&self) -> Result<CacheStats> {
        let mut s = CacheStats::default();
        for p in self.files()? {
            s.bytes += Self::length(&p);
            s.files += 1;
        }
        Ok(s)
    }
    pub fn clear(&mut self) -> Result<CacheStats> {
        let mut s = CacheStats::default();
        for p in self.files()? {
            let n = Self::length(&p);
            fs::remove_file(p)?;
            s.bytes += n;
            s.files += 1;
        }
        self.save()?;
        Ok(s)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_resume_verify_and_reject_out_of_order_or_corrupt_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = FontCache::new(dir.path().into());
        let hash = FontHash(Sha256::digest(b"font bytes").iter().map(|byte| format!("{byte:02x}")).collect());
        assert_eq!(cache.begin(&hash, 10, false).unwrap(), 0);
        assert_eq!(cache.append(&hash, 10, 0, b"font ").unwrap(), 5);
        assert!(cache.append(&hash, 10, 0, b"oops").is_err());
        assert_eq!(cache.begin(&hash, 10, false).unwrap(), 5);
        assert!(cache.finish(&hash, 10).is_err());
        cache.append(&hash, 10, 5, b"bytes").unwrap();
        let path = cache.finish(&hash, 10).unwrap();
        assert_eq!(cache.hash(&path).unwrap(), hash);
        assert_eq!(cache.stats().unwrap().files, 1);
        cache.begin(&hash, 10, false).unwrap();
        cache.append(&hash, 10, 0, b"bad bytes!").unwrap();
        assert!(cache.finish(&hash, 10).is_err());
        assert!(!cache.partial(&hash).exists());
        assert!(path.is_file());
        assert_eq!(cache.clear().unwrap().files, 1);
    }
    #[test]
    fn cache_revalidates_changed_file_and_reuses_persisted_digest() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("local.ttf");
        fs::write(&p, b"first").unwrap();
        let mut cache = FontCache::new(dir.path().join("cache"));
        let before = cache.hash(&p).unwrap();
        let mut reloaded = FontCache::new(dir.path().join("cache"));
        assert_eq!(reloaded.hash(&p).unwrap(), before);
        fs::write(&p, b"changed length").unwrap();
        assert_ne!(reloaded.hash(&p).unwrap(), before);
        assert!(FontHash::parse("../escape").is_err());
    }
}
