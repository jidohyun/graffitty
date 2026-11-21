//! Clipboard attachments follow Herdr's file/text/image routing. Platform
//! adapters supply bytes; Rust validates and normalizes before remote upload.
//! Adapted from herdr-app::terminal::paste_image_bytes; see NOTICE.
use anyhow::{Result, ensure};
use graffitty_protocol::file_transfer::MAX_BYTES;
use std::{io::{Cursor, Read}, path::Path};

pub struct Attachment { pub name: String, pub bytes: Vec<u8> }
impl Attachment {
    pub fn file(path: &Path) -> Result<Self> {
        let mut open = std::fs::OpenOptions::new();
        open.read(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; open.custom_flags(libc::O_NONBLOCK); }
        let file = open.open(path)?;
        ensure!(file.metadata()?.is_file(), "Expected a regular file");
        let mut bytes = Vec::new();
        file.take(MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= MAX_BYTES, "File exceeds the 32 MiB upload limit");
        let name = path.file_name().and_then(|s| s.to_str()).ok_or_else(|| anyhow::anyhow!("Invalid filename"))?.into();
        Ok(Self { name, bytes })
    }
    pub fn image(bytes: Vec<u8>) -> Result<Self> {
        ensure!(bytes.len() <= MAX_BYTES, "Image exceeds the 32 MiB upload limit");
        let format = image::guess_format(&bytes)?;
        let mut reader = image::ImageReader::with_format(Cursor::new(&bytes), format);
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(16384);
        limits.max_image_height = Some(16384);
        limits.max_alloc = Some(128 * 1024 * 1024);
        reader.limits(limits);
        let decoded = reader.decode()?;
        // Keep supported original encodings; normalize TIFF/BMP as Herdr does.
        let (extension, bytes) = match format {
            image::ImageFormat::Png => ("png", bytes),
            image::ImageFormat::Jpeg => ("jpg", bytes),
            image::ImageFormat::WebP => ("webp", bytes),
            image::ImageFormat::Gif => ("gif", bytes),
            _ => {
                let mut png = Cursor::new(Vec::new());
                decoded.write_to(&mut png, image::ImageFormat::Png)?;
                ("png", png.into_inner())
            }
        };
        ensure!(bytes.len() <= MAX_BYTES, "Image exceeds the 32 MiB upload limit");
        Ok(Self { name: format!("clipboard.{extension}"), bytes })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_bitmap_formats_become_png_and_corrupt_images_fail() {
        let pixels = image::DynamicImage::new_rgba8(3, 2);
        for format in [image::ImageFormat::Tiff, image::ImageFormat::Bmp, image::ImageFormat::Png] {
            let mut bytes = Cursor::new(Vec::new());
            pixels.write_to(&mut bytes, format).unwrap();
            let attachment = Attachment::image(bytes.into_inner()).unwrap();
            assert_eq!(attachment.name, "clipboard.png");
            assert_eq!(image::load_from_memory(&attachment.bytes).unwrap().width(), 3);
        }
        assert!(Attachment::image(b"not an image".to_vec()).is_err());
    }
}
