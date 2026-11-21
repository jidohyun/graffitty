//! Reuse byte-identical embedded fonts without network or disk copies.
use godot::{classes::{IRefCounted, RefCounted}, prelude::*};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, rc::Rc, sync::OnceLock};

// One static per font: a second `include_bytes!` of the same file would put a
// second copy of it (22 MB for the set) into the library.
pub static REGULAR: &[u8] = include_bytes!("../fonts/JetBrainsMonoNerdFont-Regular.ttf");
pub static BOLD: &[u8] = include_bytes!("../fonts/JetBrainsMonoNerdFont-Bold.ttf");
pub static ITALIC: &[u8] = include_bytes!("../fonts/JetBrainsMonoNerdFont-Italic.ttf");
pub static BOLD_ITALIC: &[u8] = include_bytes!("../fonts/JetBrainsMonoNerdFont-BoldItalic.ttf");
pub static NOTO_EMOJI: &[u8] = include_bytes!("../fonts/NotoEmoji-Regular.ttf");
pub static JULIA_MONO: &[u8] = include_bytes!("../fonts/JuliaMono-Regular.ttf");
pub static NOTO_COLOR_EMOJI: &[u8] = include_bytes!("../fonts/NotoColorEmoji.ttf");

pub fn bundled(hash: &str) -> Option<&'static [u8]> {
    static FILES: OnceLock<BTreeMap<String, &'static [u8]>> = OnceLock::new();
    FILES.get_or_init(|| {
        let files: [&[u8]; 7] = [
            REGULAR,
            BOLD,
            ITALIC,
            BOLD_ITALIC,
            NOTO_EMOJI,
            JULIA_MONO,
            NOTO_COLOR_EMOJI,
        ];
        files.into_iter().map(|bytes| (Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect(), bytes)).collect()
    }).get(hash).copied()
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct ServerFontAssets {
    base: Base<RefCounted>,
    // Clearing the disk cache must not invalidate fonts in a live connection,
    // including panes created after the clear action.
    retained: Option<Rc<crate::font::Fonts>>,
}
#[godot_api]
impl IRefCounted for ServerFontAssets {
    fn init(base: Base<RefCounted>) -> Self { Self { base, retained: None } }
}
#[godot_api]
impl ServerFontAssets {
    #[func]
    fn bundled_path(&self, hash: GString) -> GString {
        let hash = hash.to_string();
        if bundled(&hash).is_some() { GString::from(&format!("bundled://{hash}")) } else { GString::new() }
    }
    #[func]
    fn retain_fonts(&mut self, document: GString) -> bool {
        let result = serde_json::from_str(&document.to_string()).map_err(|e| e.to_string())
            .and_then(|faces| crate::font::Fonts::server(&faces));
        match result {
            Ok(fonts) => { self.retained = Some(fonts); true }
            Err(_) => false,
        }
    }
}
