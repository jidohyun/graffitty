//! Measured font geometry supplied by a frontend; no font loading or shaping.
/// Ratios come from the same face used for glyphs; font size is in logical pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FaceMetrics {
    pub advance: f32,
    pub ascent: f32,
    pub descent: f32,
    pub gap: f32,
}
impl Default for FaceMetrics {
    fn default() -> Self {
        Self {
            advance: 0.6,
            ascent: 1.02,
            descent: 0.3,
            gap: 0.,
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellMetrics {
    pub line_height: f32,
    pub column_width: f32,
    pub face: FaceMetrics,
}
impl Default for CellMetrics {
    fn default() -> Self {
        Self {
            line_height: 1.,
            column_width: 1.,
            face: Default::default(),
        }
    }
}
impl CellMetrics {
    fn line(self, size: f32) -> f32 {
        (self.face.ascent * size).ceil()
            + (self.face.descent * size).ceil()
            + (self.face.gap * size).ceil()
    }
    pub fn cell_size(self, size: f32) -> (u32, u32) {
        // Godot's AUTO subpixel positioning keeps fractional advances through
        // 20px, then snaps larger glyph advances to integer pixels.
        let advance = if size <= 20. {
            (size * self.face.advance * 64.).round() / 64.
        } else {
            (size * self.face.advance).round()
        };
        (
            (advance * self.column_width).ceil().max(1.) as u32,
            (self.line(size) * self.line_height).ceil().max(1.) as u32,
        )
    }
    pub fn baseline(self, size: f32) -> f32 {
        ((self.face.ascent * size).ceil() + (self.cell_size(size).1 as f32 - self.line(size)) * 0.5)
            .round()
    }
}
