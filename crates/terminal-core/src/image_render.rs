//! Visible Kitty images, including placements carried by Unicode cells.
//! libghostty-vt exposes virtual placement metadata but not its Unicode
//! renderer. Resolve those cells here so erasing, moving, scrolling and
//! alternate-screen changes naturally determine their lifetime.
use libghostty_vt::{
    Terminal,
    error::Result,
    kitty::graphics as kg,
    style::StyleColor,
    terminal::{Point, PointCoordinate},
};
use std::collections::BTreeMap;

include!("kitty_diacritics.rs");
#[cfg(test)]
#[path = "image_render_tests.rs"]
mod tests;
pub const PLACEHOLDER: char = '\u{10eeee}';

#[derive(Clone, Debug)]
pub struct Placement {
    pub image_id: u32,
    pub placement_id: u32,
    pub z: i32,
    /// Pixel rectangles (x, y, width, height), relative to the viewport origin.
    pub dest: [f32; 4],
    pub source: [f32; 4],
}

#[derive(Clone, Copy)]
struct Virtual {
    width: u32,
    height: u32,
    cols: u32,
    rows: u32,
    z: i32,
}

#[derive(Clone, Copy)]
struct Address {
    low: u32,
    high: u32,
    placement: u32,
    row: u32,
    col: u32,
}

fn color_id(color: StyleColor) -> u32 {
    match color {
        StyleColor::None => 0,
        StyleColor::Palette(index) => u32::from(index.0),
        StyleColor::Rgb(rgb) => {
            (u32::from(rgb.r) << 16) | (u32::from(rgb.g) << 8) | u32::from(rgb.b)
        }
    }
}

/// Geometry uses the frontend's cell size; callers add their own padding and
/// scroll animation, and clip the resulting rectangles to the viewport.
pub fn placements(vt: &Terminal<'_, '_>, cell: (f32, f32)) -> Result<Vec<Placement>> {
    let Some(graphics) = vt.kitty_graphics()? else { return Ok(Vec::new()) };
    let mut iterator = kg::PlacementIterator::new()?;
    let mut iter = iterator.update(&graphics)?;
    let mut output = Vec::new();
    let mut virtuals = BTreeMap::new();
    while let Some(p) = iter.next() {
        let id = p.image_id()?;
        let Some(image) = graphics.image(id) else {
            continue;
        };
        if p.is_virtual()? {
            let (width, height) = (image.width()?, image.height()?);
            let cols = match p.columns()? {
                0 => (width as f32 / cell.0).ceil() as u32,
                n => n,
            };
            let rows = match p.rows()? {
                0 => (height as f32 / cell.1).ceil() as u32,
                n => n,
            };
            virtuals.insert(
                (id, p.placement_id()?),
                Virtual {
                    width,
                    height,
                    cols,
                    rows,
                    z: p.z()?,
                },
            );
        } else {
            let info = p.placement_render_info(&image, vt)?;
            if info.viewport_visible && info.pixel_width > 0 && info.pixel_height > 0 {
                output.push(Placement {
                    image_id: id,
                    placement_id: p.placement_id()?,
                    z: p.z()?,
                    dest: [
                        info.viewport_col as f32 * cell.0 + p.x_offset()? as f32,
                        info.viewport_row as f32 * cell.1 + p.y_offset()? as f32,
                        info.pixel_width as f32,
                        info.pixel_height as f32,
                    ],
                    source: [
                        info.source_x as f32,
                        info.source_y as f32,
                        info.source_width as f32,
                        info.source_height as f32,
                    ],
                });
            }
        }
    }
    resolve_virtuals(vt, cell, virtuals, output)
}

fn resolve_virtuals(vt: &Terminal<'_, '_>, cell: (f32, f32), virtuals: BTreeMap<(u32, u32), Virtual>, mut output: Vec<Placement>) -> Result<Vec<Placement>> {
    if !virtuals.is_empty() {
        let mut chars = vec!['\0'; 8];
        for y in 0..vt.rows()? {
            let at = |x| vt.grid_ref(Point::Viewport(PointCoordinate { x, y: u32::from(y) }));
            if !at(0)?.row()?.has_kitty_virtual_placeholder()? {
                continue;
            }
            let mut previous: Option<Address> = None;
            for x in 0..vt.cols()? {
                let grid = at(x)?;
                if grid.cell()?.codepoint()? != PLACEHOLDER as u32 {
                    previous = None;
                    continue;
                }
                let n = match grid.graphemes(&mut chars) {
                    Err(libghostty_vt::Error::OutOfSpace { required }) => {
                        chars.resize(required, '\0');
                        grid.graphemes(&mut chars)?
                    }
                    result => result?,
                };
                let number = |i: usize| {
                    chars
                        .get(i)
                        .filter(|_| i < n)
                        .and_then(|c| DIACRITICS.binary_search(c).ok())
                        .map(|n| n as u32)
                };
                let style = grid.style()?;
                let low = color_id(style.fg_color);
                let placement = color_id(style.underline_color);
                let (row, col, high) = (number(1), number(2), number(3).filter(|n| *n <= 255));
                let inherited = previous.filter(|p| {
                    p.low == low
                        && p.placement == placement
                        && row.is_none_or(|n| n == p.row)
                        && col.is_none_or(|n| n == p.col + 1)
                        && high.is_none_or(|n| n == p.high)
                });
                let address = Address {
                    low,
                    placement,
                    row: row.or(inherited.map(|p| p.row)).unwrap_or(0),
                    col: col.or(inherited.map(|p| p.col + 1)).unwrap_or(0),
                    high: high.or(inherited.map(|p| p.high)).unwrap_or(0),
                };
                previous = Some(address);
                let id = low | (address.high << 24);
                let template = if placement == 0 {
                    virtuals.range((id, 0)..=(id, u32::MAX)).next()
                } else {
                    virtuals.get_key_value(&(id, placement))
                };
                let Some(((_, pid), template)) = template else {
                    continue;
                };
                if let Some(mut quad) = virtual_cell(*template, address, (x, y), cell) {
                    quad.image_id = id;
                    quad.placement_id = *pid;
                    // Merge neighboring cells into strips without joining
                    // across erased cells or changes to image coordinates.
                    if let Some(last) = output.last_mut().filter(|last| {
                        last.image_id == id
                            && last.placement_id == *pid
                            && last.z == quad.z
                            && last.dest[1] == quad.dest[1]
                            && last.dest[3] == quad.dest[3]
                            && (last.dest[0] + last.dest[2] - quad.dest[0]).abs() < 0.001
                            && last.source[1] == quad.source[1]
                            && last.source[3] == quad.source[3]
                            && (last.source[0] + last.source[2] - quad.source[0]).abs() < 0.001
                    }) {
                        last.dest[2] += quad.dest[2];
                        last.source[2] += quad.source[2];
                    } else {
                        output.push(quad);
                    }
                }
            }
        }
    }
    output.sort_by_key(|p| (p.z, p.image_id, p.placement_id));
    Ok(output)
}

fn virtual_cell(v: Virtual, a: Address, at: (u16, u16), cell: (f32, f32)) -> Option<Placement> {
    if a.col >= v.cols || a.row >= v.rows || v.width == 0 || v.height == 0 {
        return None;
    }
    let scale =
        (v.cols as f32 * cell.0 / v.width as f32).min(v.rows as f32 * cell.1 / v.height as f32);
    let left = (v.cols as f32 * cell.0 - v.width as f32 * scale) / 2.0;
    let top = (v.rows as f32 * cell.1 - v.height as f32 * scale) / 2.0;
    let x0 = (a.col as f32 * cell.0).max(left);
    let y0 = (a.row as f32 * cell.1).max(top);
    let x1 = ((a.col + 1) as f32 * cell.0).min(left + v.width as f32 * scale);
    let y1 = ((a.row + 1) as f32 * cell.1).min(top + v.height as f32 * scale);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some(Placement {
        image_id: 0,
        placement_id: 0,
        z: v.z,
        dest: [
            (at.0 as f32 - a.col as f32) * cell.0 + x0,
            (at.1 as f32 - a.row as f32) * cell.1 + y0,
            x1 - x0,
            y1 - y0,
        ],
        source: [
            (x0 - left) / scale,
            (y0 - top) / scale,
            (x1 - x0) / scale,
            (y1 - y0) / scale,
        ],
    })
}

/// Resolve the owner's placement state using this viewer's scroll position and
/// cell geometry. No pixels or application graphics commands enter the replica.
pub fn scene_placements(vt: &Terminal<'_, '_>, scene: &graffitty_protocol::terminal_scene::Graphics, cell: (f32, f32)) -> Result<Vec<Placement>> {
    let images: BTreeMap<_, _> = scene.images.iter().map(|image| (image.id, image)).collect();
    let mut virtuals = BTreeMap::new();
    let mut output = Vec::new();
    let top = vt.scrollbar()?.offset as f32;
    let bottom = vt.rows()? as f32 * cell.1;
    for p in &scene.placements {
        let Some(image) = images.get(&p.image) else { continue };
        if p.virtual_ {
            virtuals.insert((p.image, p.id), Virtual {
                width: image.width, height: image.height, z: p.z,
                cols: if p.columns == 0 { (image.width as f32 / cell.0).ceil() as u32 } else { p.columns },
                rows: if p.rows == 0 { (image.height as f32 / cell.1).ceil() as u32 } else { p.rows },
            });
            continue;
        }
        let [sx, sy, sw, sh] = p.source;
        let sw = if sw == 0 { image.width.saturating_sub(sx) } else { sw.min(image.width.saturating_sub(sx)) } as f32;
        let sh = if sh == 0 { image.height.saturating_sub(sy) } else { sh.min(image.height.saturating_sub(sy)) } as f32;
        if sw == 0. || sh == 0. { continue }
        let (w, h) = match (p.columns, p.rows) {
            (0, 0) => (sw, sh),
            (cols, 0) => { let w = cols as f32 * cell.0; (w, sh * w / sw) },
            (0, rows) => { let h = rows as f32 * cell.1; (sw * h / sh, h) },
            (cols, rows) => (cols as f32 * cell.0, rows as f32 * cell.1),
        };
        let x = p.column as f32 * cell.0 + p.offset[0] as f32;
        let y = (p.row as f32 - top) * cell.1 + p.offset[1] as f32;
        if y >= bottom || y + h <= 0. { continue }
        output.push(Placement { image_id: p.image, placement_id: p.id, z: p.z,
            dest: [x, y, w, h], source: [sx as f32, sy as f32, sw, sh] });
    }
    resolve_virtuals(vt, cell, virtuals, output)
}
