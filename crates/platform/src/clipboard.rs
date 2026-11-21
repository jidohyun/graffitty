//! Clipboard ownership lasts for the workspace. Background tests never access the OS.
use crate::clipboard_core::Data;
use anyhow::{Result, ensure};
use std::sync::Arc;

#[derive(Default)]
pub struct Clipboard {
    pub primary: String,
    system: Option<arboard::Clipboard>,
    data: Data,
    primary_data: Data,
}
impl Clipboard {
    pub fn has_system_clipboard(&self) -> bool {
        self.system.is_some()
    }
    fn system(&mut self) -> Result<&mut arboard::Clipboard> {
        if self.system.is_none() {
            self.system = Some(arboard::Clipboard::new()?);
        }
        Ok(self.system.as_mut().unwrap())
    }
    pub fn write_text(&mut self, text: &str, headless: bool, clipboard: &mut String) -> Result<()> {
        if !headless {
            self.system()?.set_text(text.to_owned())?;
        }
        *clipboard = text.into();
        self.data = Data::from([("text/plain".into(), Arc::new(text.as_bytes().to_vec()))]);
        Ok(())
    }
    pub fn text(&mut self, headless: bool, clipboard: &str) -> Result<String> {
        if headless {
            Ok(clipboard.into())
        } else {
            Ok(self.system()?.get_text()?)
        }
    }
    pub fn image_png(&mut self, headless: bool) -> Result<Option<Vec<u8>>> {
        if headless { return Ok(self.data.get("image/png").map(|b| b.as_ref().clone())); }
        let bitmap = match self.system()?.get_image() {
            Ok(bitmap) => bitmap,
            Err(arboard::Error::ContentNotAvailable) => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        ensure!(bitmap.bytes.len() <= 128 * 1024 * 1024, "Clipboard image is too large");
        let mut png = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut png, bitmap.width.try_into()?, bitmap.height.try_into()?);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.write_header()?.write_image_data(&bitmap.bytes)?;
        }
        Ok(Some(png))
    }
    pub fn selected(
        &mut self,
        text: &str,
        policy: &str,
        headless: bool,
        clipboard: &mut String,
    ) -> Result<()> {
        if text.is_empty() {
            return Ok(());
        }
        if matches!(policy, "primary" | "both") {
            self.write_primary(text, headless)?;
        }
        if matches!(policy, "clipboard" | "both") {
            self.write_text(text, headless, clipboard)?;
        }
        Ok(())
    }
    fn write_primary(&mut self, text: &str, headless: bool) -> Result<()> {
        #[cfg(target_os = "linux")]
        if !headless {
            use arboard::{LinuxClipboardKind, SetExtLinux};
            self.system()?
                .set()
                .clipboard(LinuxClipboardKind::Primary)
                .text(text.to_owned())?;
        }
        let _ = headless;
        self.primary = text.into();
        self.primary_data = Data::from([("text/plain".into(), Arc::new(text.as_bytes().to_vec()))]);
        Ok(())
    }
    pub fn primary(&mut self, headless: bool) -> Result<String> {
        #[cfg(target_os = "linux")]
        if !headless {
            use arboard::{GetExtLinux, LinuxClipboardKind};
            return Ok(self
                .system()?
                .get()
                .clipboard(LinuxClipboardKind::Primary)
                .text()?);
        }
        let _ = headless;
        Ok(self.primary.clone())
    }
    pub fn write_rich(
        &mut self,
        primary: bool,
        data: Data,
        headless: bool,
        clipboard: &mut String,
    ) -> Result<()> {
        let text = data
            .get("text/plain")
            .and_then(|s| std::str::from_utf8(s).ok())
            .unwrap_or("")
            .to_owned();
        if !headless {
            #[cfg(target_os = "macos")]
            if !primary {
                ensure!(
                    crate::clipboard_macos::write(&data),
                    "Could not write clipboard formats"
                );
            }
            #[cfg(not(target_os = "macos"))]
            if !primary {
                ensure!(
                    data.get("text/plain")
                        .is_some_and(|b| std::str::from_utf8(b).is_ok()),
                    "Native clipboard requires plain text on this platform"
                );
                self.system()?.set_text(text.clone())?;
            }
            if primary {
                self.write_primary(&text, false)?;
            }
        }
        if primary {
            self.primary = text;
            self.primary_data = data;
        } else {
            *clipboard = text;
            self.data = data;
        }
        Ok(())
    }
    pub fn read_rich(
        &mut self,
        primary: bool,
        mime: &str,
        headless: bool,
        clipboard: &str,
    ) -> Option<Vec<u8>> {
        if !headless {
            #[cfg(target_os = "macos")]
            if !primary {
                return crate::clipboard_macos::get(mime);
            }
            if mime == "." {
                return Some(b"text/plain".to_vec());
            }
            return (mime == "text/plain")
                .then(|| {
                    if primary {
                        self.primary(false)
                    } else {
                        self.text(false, clipboard)
                    }
                })
                .and_then(Result::ok)
                .map(String::into_bytes);
        }
        let data = if primary {
            &self.primary_data
        } else {
            &self.data
        };
        if mime == "." {
            return Some(if data.is_empty() {
                b"text/plain".to_vec()
            } else {
                data.keys()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .into_bytes()
            });
        }
        data.get(mime)
            .map(|bytes| bytes.as_ref().clone())
            .or_else(|| {
                (mime == "text/plain").then(|| {
                    if primary {
                        self.primary.as_bytes().to_vec()
                    } else {
                        clipboard.as_bytes().to_vec()
                    }
                })
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn headless_rich_clipboard_preserves_formats_and_text_copy_replaces_them() {
        let mut service = Clipboard::default();
        let mut text = String::new();
        service
            .write_rich(
                false,
                Data::from([
                    ("image/png".into(), Arc::new(vec![0, 255, 0])),
                    ("text/plain".into(), Arc::new("한글".as_bytes().to_vec())),
                ]),
                true,
                &mut text,
            )
            .unwrap();
        assert_eq!(text, "한글");
        assert_eq!(
            service.read_rich(false, "image/png", true, &text),
            Some(vec![0, 255, 0])
        );
        service
            .selected("primary only", "primary", true, &mut text)
            .unwrap();
        assert_eq!(service.primary(true).unwrap(), "primary only");
        assert_eq!(service.text(true, &text).unwrap(), "한글");
        service.write_text("replacement", true, &mut text).unwrap();
        assert!(service.read_rich(false, "image/png", true, &text).is_none());
        assert_eq!(
            service.read_rich(false, ".", true, &text).unwrap(),
            b"text/plain"
        );
        assert!(
            service.system.is_none(),
            "Offscreen operations must never construct an OS clipboard"
        );
    }
}
