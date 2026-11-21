//! Extract immutable resources and placement metadata from the owning VT.
//! No frontend opens source paths, decodes terminal graphics commands, or
//! decides whether an application-owned placement still exists.
use crate::{Error, images};
use graffitty_protocol::terminal_scene::{AssetKey, Graphics, Image, Placement};
use libghostty_vt::{Terminal, kitty::graphics as kg, terminal::PointSpace};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};

#[derive(Clone)]
pub struct Asset {
    pub key: AssetKey,
    pub width: u32,
    pub height: u32,
    pub rgba: Arc<[u8]>,
    pub png: Option<Arc<[u8]>>,
}

#[derive(Default)]
pub struct Publisher {
    versions: BTreeMap<(bool, u32), (u64, AssetKey)>,
    pub assets: BTreeMap<AssetKey, Arc<Asset>>,
}

impl Publisher {
    pub fn clear(&mut self) {
        self.versions.clear();
        self.assets.clear();
    }

    pub fn capture(
        &mut self,
        vt: &Terminal<'_, '_>,
        originals: &images::State,
    ) -> Result<Graphics, Error> {
        let screen = vt.active_screen()? == libghostty_vt::screen::Screen::Alternate;
        let Some(graphics) = vt.kitty_graphics()? else {
            self.assets.clear();
            return Ok(Graphics::default());
        };
        let mut iterator = kg::PlacementIterator::new()?;
        let mut placements = iterator.update(&graphics)?;
        let mut out = Graphics::default();
        let mut used = BTreeSet::new();
        while let Some(p) = placements.next() {
            let id = p.image_id()?;
            let Some(image) = graphics.image(id) else {
                continue;
            };
            let generation = image.generation()?;
            let (width, height) = (image.width()?, image.height()?);
            let asset = match self
                .versions
                .get(&(screen, id))
                .filter(|(g, _)| *g == generation)
            {
                Some((_, key)) => key.clone(),
                None => {
                    let channels = match image.format()? {
                        kg::ImageFormat::Rgba => 4,
                        kg::ImageFormat::Rgb => 3,
                        kg::ImageFormat::GrayAlpha => 2,
                        kg::ImageFormat::Gray => 1,
                        _ => return Err("Owner image is not decoded".into()),
                    };
                    let raw = image.data()?.ok_or("Owner image has no pixels")?;
                    if image.compression()? != kg::Compression::None
                        || raw.len() != width as usize * height as usize * channels
                    {
                        return Err("Invalid owner image pixels".into());
                    }
                    let rgba: Arc<[u8]> = if channels == 4 {
                        Arc::from(raw)
                    } else {
                        raw.chunks_exact(channels)
                            .flat_map(|p| match channels {
                                3 => [p[0], p[1], p[2], 255],
                                2 => [p[0], p[0], p[0], p[1]],
                                _ => [p[0], p[0], p[0], 255],
                            })
                            .collect::<Vec<_>>()
                            .into()
                    };
                    let mut hash = blake3::Hasher::new();
                    hash.update(&width.to_le_bytes());
                    hash.update(&height.to_le_bytes());
                    hash.update(&rgba);
                    let key = AssetKey(hash.finalize().to_hex().to_string());
                    self.assets.entry(key.clone()).or_insert_with(|| {
                        Arc::new(Asset {
                            key: key.clone(),
                            width,
                            height,
                            rgba,
                            png: originals.original(vt, id, generation),
                        })
                    });
                    self.versions
                        .insert((screen, id), (generation, key.clone()));
                    key
                }
            };
            if used.insert(id) {
                out.images.push(Image {
                    id,
                    asset,
                    width,
                    height,
                });
            }
            let virtual_ = p.is_virtual()?;
            let (column, row) = if virtual_ {
                (0, 0)
            } else {
                let Some(rect) = p.rect(&image, vt)? else { continue };
                let Some(point) = vt.point_from_grid_ref(&rect.start(), PointSpace::Screen)? else {
                    continue;
                };
                (point.x, point.y)
            };
            out.placements.push(Placement {
                image: id,
                id: p.placement_id()?,
                z: p.z()?,
                virtual_,
                column,
                row,
                columns: p.columns()?,
                rows: p.rows()?,
                offset: [p.x_offset()?, p.y_offset()?],
                source: [
                    p.source_x()?,
                    p.source_y()?,
                    p.source_width()?,
                    p.source_height()?,
                ],
            });
        }
        // Keep versions of invisible retained images. Reusing a placement must
        // not copy/hash/upload its pixels again. Deleted assets are reclaimed.
        self.versions
            .retain(|(s, id), _| *s != screen || graphics.image(*id).is_some());
        let retained: BTreeSet<_> = self.versions.values().map(|(_, key)| key).collect();
        self.assets.retain(|key, _| retained.contains(key));
        out.images.sort_by_key(|v| v.id);
        out.placements.sort_by_key(|v| (v.z, v.image, v.id));
        Ok(out)
    }
}

pub fn decode_asset(
    chunk: &graffitty_protocol::terminal_scene::AssetChunk,
    data: Vec<u8>,
) -> Result<Arc<[u8]>, Error> {
    let rgba: Arc<[u8]> = match chunk.format.as_str() {
        "rgba" if data.len() == chunk.width as usize * chunk.height as usize * 4 => data.into(),
        "png" => {
            let decoder = image::ImageReader::with_format(
                std::io::Cursor::new(&data),
                image::ImageFormat::Png,
            );
            let (w, h) = decoder.into_dimensions()?;
            if (w, h) != (chunk.width, chunk.height) {
                return Err("Image dimensions do not match resource".into());
            }
            image::load_from_memory_with_format(&data, image::ImageFormat::Png)?
                .to_rgba8()
                .into_raw()
                .into()
        }
        _ => return Err("Invalid image resource encoding".into()),
    };
    let mut hash = blake3::Hasher::new();
    hash.update(&chunk.width.to_le_bytes());
    hash.update(&chunk.height.to_le_bytes());
    hash.update(&rgba);
    if hash.finalize().to_hex().as_str() != chunk.asset.0 {
        return Err("Image content hash mismatch".into());
    }
    Ok(rgba)
}
