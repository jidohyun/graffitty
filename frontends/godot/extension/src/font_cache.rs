//! Filesystem adapter for the frontend-independent verified font cache.
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_client_core::font_cache::{FontCache, FontHash};
use std::path::Path;
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct FontCacheStore {
    base: Base<RefCounted>,
    cache: FontCache,
    error: String,
}
#[godot_api]
impl IRefCounted for FontCacheStore {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            cache: FontCache::default(),
            error: String::new(),
        }
    }
}
impl FontCacheStore {
    fn result<T: Default>(&mut self, result: anyhow::Result<T>) -> T {
        match result {
            Ok(value) => {
                self.error.clear();
                value
            }
            Err(e) => {
                self.error = format!("{e:#}");
                T::default()
            }
        }
    }
}
#[godot_api]
impl FontCacheStore {
    #[func]
    fn configure(&mut self, directory: GString) {
        self.cache = FontCache::new(directory.to_string().into());
        self.error.clear();
    }
    #[func]
    fn last_error(&self) -> GString {
        self.error.as_str().into()
    }
    #[func]
    fn hash(&mut self, path: GString) -> GString {
        let result = self
            .cache
            .hash(Path::new(&path.to_string()))
            .map(|h| GString::from(h.as_str()));
        self.result(result)
    }
    #[func]
    fn remember(&mut self, path: GString, digest: GString) {
        let result = FontHash::parse(&digest.to_string())
            .and_then(|h| self.cache.remember(Path::new(&path.to_string()), h));
        self.result(result);
    }
    #[func]
    fn begin_download(&mut self, digest: GString, length: i64, mobile: bool) -> i64 {
        let result = FontHash::parse(&digest.to_string())
            .and_then(|h| self.cache.begin(&h, length.try_into()?, mobile));
        match result {
            Ok(v) => {
                self.error.clear();
                v as i64
            }
            Err(e) => {
                self.error = format!("{e:#}");
                -1
            }
        }
    }
    #[func]
    fn append_download(
        &mut self,
        digest: GString,
        length: i64,
        offset: i64,
        data: PackedByteArray,
    ) -> i64 {
        let result = FontHash::parse(&digest.to_string()).and_then(|h| {
            self.cache
                .append(&h, length.try_into()?, offset.try_into()?, data.as_slice())
        });
        match result {
            Ok(v) => {
                self.error.clear();
                v as i64
            }
            Err(e) => {
                self.error = format!("{e:#}");
                -1
            }
        }
    }
    #[func]
    fn finish_download(&mut self, digest: GString, length: i64) -> GString {
        let result = FontHash::parse(&digest.to_string())
            .and_then(|h| self.cache.finish(&h, length.try_into()?))
            .map(|p| GString::from(p.to_string_lossy().as_ref()));
        self.result(result)
    }
    #[func]
    fn length(&self, path: GString) -> i64 {
        FontCache::length(Path::new(&path.to_string())) as i64
    }
    #[func]
    fn adopt_partial(&mut self, path: GString, temporary: GString, mobile: bool) {
        let result = self.cache.adopt_partial(
            Path::new(&path.to_string()),
            Path::new(&temporary.to_string()),
            std::time::Duration::from_secs(if mobile { 0 } else { 120 }),
        );
        self.result(result);
    }
    #[func]
    fn stats(&mut self) -> VarDictionary {
        let result = self.cache.stats();
        let value = self.result(result);
        let mut d = VarDictionary::new();
        d.set("bytes", value.bytes as i64);
        d.set("files", value.files as i64);
        d
    }
    #[func]
    fn files(&mut self) -> Array<GString> {
        let result = self.cache.files();
        self.result(result)
            .iter()
            .filter_map(|p| {
                p.file_name()
                    .map(|n| GString::from(n.to_string_lossy().as_ref()))
            })
            .collect()
    }
    #[func]
    fn clear(&mut self) -> VarDictionary {
        let result = self.cache.clear();
        let value = self.result(result);
        let mut d = VarDictionary::new();
        d.set("bytes", value.bytes as i64);
        d.set("files", value.files as i64);
        d.set("error", self.error.as_str());
        d
    }
}
