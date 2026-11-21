use super::{Options, Place, Result, WindowSize};
use image::{AnimationDecoder, DynamicImage, ImageDecoder, ImageFormat, RgbaImage};
use std::io::Cursor;

pub(super) struct Frame {
    pub pixels: RgbaImage,
    pub delay: i32,
}

pub(super) struct Decoded {
    pub frames: Vec<Frame>,
}

pub(super) fn background(value: &str) -> Result<[u8; 4]> {
    // Kitty also accepts X11's rgb:RR/GG/BB notation.
    if let Some(rgb) = value.strip_prefix("rgb:") {
        let channels = rgb
            .split('/')
            .map(|s| {
                if s.is_empty() || s.len() > 4 {
                    return Err("Invalid rgb: color".into());
                }
                let value = u16::from_str_radix(s, 16)?;
                Ok((u32::from(value) * 255 / ((1u32 << (4 * s.len())) - 1)) as u8)
            })
            .collect::<Result<Vec<_>>>()?;
        if let [r, g, b] = channels.as_slice() {
            return Ok([*r, *g, *b, 255]);
        }
        return Err("Expected rgb:RED/GREEN/BLUE".into());
    }
    Ok(value.parse::<csscolorparser::Color>()?.to_rgba8())
}

fn frames<'a>(frames: image::Frames<'a>, first_only: bool) -> Result<Decoded> {
    let mut result = Vec::new();
    let mut size = 0usize;
    for frame in frames.take(if first_only { 1 } else { usize::MAX }) {
        let frame = frame?;
        let (numerator, denominator) = frame.delay().numer_denom_ms();
        let delay = (numerator / denominator).min(i32::MAX as u32) as i32;
        let pixels = frame.into_buffer();
        size = size.saturating_add(pixels.len());
        if size > super::MAX_INPUT as usize {
            return Err("Decoded animation exceeds 256 MiB".into());
        }
        result.push(Frame {
            pixels,
            delay: if delay == 0 { -1 } else { delay },
        });
    }
    if result.is_empty() {
        return Err("Image contains no frames".into());
    }
    Ok(Decoded { frames: result })
}

fn builtin(bytes: &[u8], first_only: bool) -> Result<Decoded> {
    let format = image::guess_format(bytes)?;
    match format {
        ImageFormat::Gif => {
            return frames(
                image::codecs::gif::GifDecoder::new(Cursor::new(bytes))?.into_frames(),
                first_only,
            );
        }
        ImageFormat::WebP => {
            let decoder = image::codecs::webp::WebPDecoder::new(Cursor::new(bytes))?;
            if decoder.has_animation() {
                return frames(decoder.into_frames(), first_only);
            }
        }
        ImageFormat::Png => {
            let decoder = image::codecs::png::PngDecoder::new(Cursor::new(bytes))?;
            if decoder.is_apng()? {
                return frames(decoder.apng()?.into_frames(), first_only);
            }
        }
        _ => (),
    }
    let mut reader = image::ImageReader::with_format(Cursor::new(bytes), format);
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(super::MAX_INPUT);
    reader.limits(limits);
    let mut decoder = reader.into_decoder()?;
    let orientation = decoder.orientation()?;
    let mut image = DynamicImage::from_decoder(decoder)?;
    image.apply_orientation(orientation);
    Ok(Decoded {
        frames: vec![Frame {
            pixels: image.into_rgba8(),
            delay: 0,
        }],
    })
}

fn magick(bytes: &[u8], first_only: bool) -> Result<Decoded> {
    let directory = tempfile::tempdir()?;
    let input = directory.path().join("input");
    std::fs::write(&input, bytes)?;
    let input = if first_only {
        format!("{}[0]", input.display())
    } else {
        input.to_string_lossy().into_owned()
    };
    let invoke = |program: &str| {
        std::process::Command::new(program)
            .args(["-limit", "memory", "256MiB", "-limit", "map", "512MiB"])
            .arg(&input)
            .args([
                "-coalesce",
                "-auto-orient",
                "-depth",
                "8",
                "-format",
                "%T\n",
                "-write",
                "info:",
                "+adjoin",
            ])
            .arg(directory.path().join("frame-%08d.png"))
            .output()
    };
    let output = match invoke("magick") {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => invoke("convert"),
        result => result,
    }
    .map_err(|error| format!("ImageMagick is needed for this image (--engine=magick): {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "ImageMagick: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into());
    }
    let delays: Vec<_> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|s| s.trim().parse::<i32>().unwrap_or(0).saturating_mul(10))
        .collect();
    let mut paths = std::fs::read_dir(directory.path())?.collect::<std::io::Result<Vec<_>>>()?;
    paths.retain(|entry| entry.file_name().to_string_lossy().starts_with("frame-"));
    paths.sort_by_key(|entry| entry.file_name());
    let mut result = Vec::new();
    let mut size = 0usize;
    for (index, entry) in paths.into_iter().enumerate() {
        let pixels = image::open(entry.path())?.into_rgba8();
        size = size.saturating_add(pixels.len());
        if size > super::MAX_INPUT as usize {
            return Err("Decoded animation exceeds 256 MiB".into());
        }
        let delay = delays.get(index).copied().unwrap_or(0);
        result.push(Frame {
            pixels,
            delay: if delay == 0 { -1 } else { delay },
        });
    }
    if result.is_empty() {
        return Err("ImageMagick produced no frames".into());
    }
    Ok(Decoded { frames: result })
}

pub(super) fn decode(bytes: &[u8], opts: &Options) -> Result<Decoded> {
    if opts.engine == "magick" {
        return magick(bytes, opts.loops == 0);
    }
    match builtin(bytes, opts.loops == 0) {
        Ok(image) => Ok(image),
        Err(error) if opts.engine == "auto" => {
            magick(bytes, opts.loops == 0).map_err(|fallback| format!("{error}; {fallback}").into())
        }
        Err(error) => Err(error),
    }
}

pub(super) fn scaled_size(
    width: u32,
    height: u32,
    opts: &Options,
    window: WindowSize,
    place: Option<Place>,
) -> (u32, u32) {
    let (max_width, max_height) = if let Some(place) = place {
        (
            f64::from(place.width) * f64::from(window.width) / f64::from(window.columns),
            f64::from(place.height) * f64::from(window.height) / f64::from(window.rows),
        )
    } else {
        (
            if matches!(opts.fit.as_str(), "width" | "both") {
                f64::from(window.width)
            } else {
                f64::INFINITY
            },
            if matches!(opts.fit.as_str(), "height" | "both") {
                f64::from(window.height)
            } else {
                f64::INFINITY
            },
        )
    };
    let scale = (max_width / f64::from(width)).min(max_height / f64::from(height));
    let scale = if !opts.scale_up.0 || !scale.is_finite() {
        scale.min(1.0)
    } else {
        scale
    };
    (
        (f64::from(width) * scale).max(1.0) as u32,
        (f64::from(height) * scale).max(1.0) as u32,
    )
}

impl Decoded {
    pub fn transform(
        &mut self,
        opts: &Options,
        size: WindowSize,
        place: Option<Place>,
        background: Option<[u8; 4]>,
    ) -> Result<()> {
        let (width, height) = self.frames[0].pixels.dimensions();
        let (target_width, target_height) = scaled_size(width, height, opts, size, place);
        if u64::from(target_width) * u64::from(target_height)
            > super::MAX_INPUT / 4 / self.frames.len() as u64
        {
            return Err("Scaled image exceeds 256 MiB".into());
        }
        for frame in &mut self.frames {
            if frame.pixels.dimensions() != (target_width, target_height) {
                frame.pixels = image::imageops::resize(
                    &frame.pixels,
                    target_width,
                    target_height,
                    image::imageops::FilterType::Lanczos3,
                );
            }
            if matches!(opts.mirror.as_str(), "horizontal" | "both") {
                image::imageops::flip_horizontal_in_place(&mut frame.pixels);
            }
            if matches!(opts.mirror.as_str(), "vertical" | "both") {
                image::imageops::flip_vertical_in_place(&mut frame.pixels);
            }
            if let Some(background) = background {
                for pixel in frame.pixels.pixels_mut() {
                    let alpha = u32::from(pixel[3]);
                    for i in 0..3 {
                        pixel[i] = ((u32::from(pixel[i]) * alpha
                            + u32::from(background[i]) * (255 - alpha)
                            + 127)
                            / 255) as u8;
                    }
                    pixel[3] = 255;
                }
            }
        }
        Ok(())
    }
}
