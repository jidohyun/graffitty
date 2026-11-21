//! Godot clipboard adapter; transfer framing and limits are shared with other frontends.
pub use crate::clipboard_core::status;
use godot::classes::{DisplayServer, display_server::Feature};
use godot::obj::Singleton;
use std::collections::BTreeMap;
use graffitty_client_core::clipboard_paste::Attachment;

pub enum Paste { Text(String), File(Attachment), Empty }

/// Called only by an explicit paste action. File/text/image ordering follows
/// Herdr; image data is staged on the terminal owner on every platform.
pub fn paste() -> anyhow::Result<Paste> {
    #[cfg(target_os = "android")]
    {
        use godot::prelude::*;
        use base64::Engine as _;
        let engine = godot::classes::Engine::singleton();
        let mut runtime = engine.get_singleton("AndroidRuntime").ok_or_else(|| anyhow::anyhow!("Android runtime unavailable"))?;
        let activity = runtime.call("getActivity", &[]);
        let mut wrapper = engine.get_singleton("JavaClassWrapper").ok_or_else(|| anyhow::anyhow!("Java bridge unavailable"))?;
        let mut class = wrapper.call("wrap", &["com.graffitty.input.TerminalClipboard".to_variant()]).to::<Gd<godot::classes::Object>>();
        let result = class.call("read", &[activity]).to::<GString>().to_string();
        let value: serde_json::Value = serde_json::from_str(&result)?;
        if let Some(error) = value["error"].as_str() { anyhow::bail!("{error}"); }
        if let Some(data) = value["image"].as_str() {
            return Ok(Paste::File(Attachment::image(base64::engine::general_purpose::STANDARD.decode(data)?)?));
        }
        if let Some(text) = value["text"].as_str() { return Ok(Paste::Text(text.into())); }
        return Ok(Paste::Empty);
    }
    #[cfg(target_os = "ios")]
    {
        unsafe extern "C" {
            fn graffitty_ios_clipboard_image(size: *mut usize) -> *mut u8;
            fn graffitty_ios_clipboard_free(data: *mut u8);
        }
        let mut size = 0;
        let bytes = unsafe {
            let ptr = graffitty_ios_clipboard_image(&mut size);
            if ptr.is_null() { None } else {
                let bytes = std::slice::from_raw_parts(ptr, size).to_vec();
                graffitty_ios_clipboard_free(ptr);
                Some(bytes)
            }
        };
        anyhow::ensure!(size != usize::MAX, "Cannot read clipboard image (maximum 32 MiB)");
        if let Some(bytes) = bytes { return Ok(Paste::File(Attachment::image(bytes)?)); }
    }
    #[cfg(target_os = "macos")]
    if let Some(paths) = crate::clipboard_macos::get("application/x-graffitty-file-paths") {
        let paths: Vec<String> = serde_json::from_slice(&paths)?;
        if let Some(path) = paths.first() { return Ok(Paste::File(Attachment::file(std::path::Path::new(path))?)); }
    }
    #[cfg(not(target_os = "android"))]
    {
        let ds = DisplayServer::singleton();
        let text = ds.clipboard_get().to_string();
        if !text.is_empty() { return Ok(Paste::Text(text)); }
        if ds.clipboard_has_image() {
            let image = ds.clipboard_get_image().ok_or_else(|| anyhow::anyhow!("Cannot read clipboard image"))?;
            let bytes = image.save_png_to_buffer().to_vec();
            return Ok(Paste::File(Attachment::image(bytes)?));
        }
        Ok(Paste::Empty)
    }
}
#[derive(Default)]
pub struct Transfer(crate::clipboard_core::Transfer);
pub enum Action {
    None,
    Reply(String),
    Read { primary: bool, types: Vec<String> },
}
impl Transfer {
    pub fn feed(&mut self, packet: &str, writable: bool) -> Action {
        use crate::clipboard_core::Action as Core;
        let primary_supported = DisplayServer::singleton().has_feature(Feature::CLIPBOARD_PRIMARY);
        match self.0.feed(packet, writable, primary_supported) {
            Core::None => Action::None,
            Core::Reply(reply) => Action::Reply(reply),
            Core::Read { primary, types } => Action::Read { primary, types },
            Core::Write { primary, data } => Action::Reply(status(
                "write",
                if write(primary, &data) { "DONE" } else { "EIO" },
            )),
        }
    }
}
pub fn read(primary: bool, types: &[String]) -> String {
    crate::clipboard_core::read_with(types, |mime| get(primary, mime))
}
pub fn write_text(primary: bool, text: &str) -> bool {
    write(primary, &BTreeMap::from([("text/plain".into(), std::sync::Arc::new(text.as_bytes().to_vec()))]))
}
fn get(primary: bool, mime: &str) -> Option<Vec<u8>> {
    #[cfg(windows)]
    if !primary {
        return crate::clipboard_windows::get(mime);
    }
    #[cfg(target_os = "macos")]
    if !primary {
        return crate::clipboard_macos::get(mime);
    }
    if mime == "." {
        return Some(b"text/plain".to_vec());
    }
    if mime != "text/plain" {
        return None;
    }
    let ds = DisplayServer::singleton();
    Some(
        (if primary {
            ds.clipboard_get_primary()
        } else {
            ds.clipboard_get()
        })
        .to_string()
        .into_bytes(),
    )
}
fn write(primary: bool, data: &BTreeMap<String, std::sync::Arc<Vec<u8>>>) -> bool {
    #[cfg(windows)]
    if !primary {
        return crate::clipboard_windows::write(data);
    }
    #[cfg(target_os = "macos")]
    if !primary {
        return crate::clipboard_macos::write(data);
    }
    let Some(text) = data
        .get("text/plain")
        .and_then(|s| std::str::from_utf8(s).ok())
    else {
        return false;
    };
    let mut ds = DisplayServer::singleton();
    if primary {
        ds.clipboard_set_primary(text);
    } else {
        ds.clipboard_set(text);
    }
    true
}
