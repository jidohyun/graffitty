//! The styling engine behind the script's fluent chain.
//!
//! Adapted from gpui-kit `crates/shell/src/style.rs` (Apache-2.0,
//! Longbridge).
//!
//! The script writes what GPUI Rust writes —
//! `v_flex().size_full().bg("#202126").p(12)` — so this module answers one
//! question for a method name: is it a style, and how does it change a
//! [`Style`]?
//!
//! gpui-kit reflects the no-argument methods out of GPUI itself.
//!
//! There is no GPUI here, so [`NULLARY`] is the hand-written list of the
//! Tailwind-style names the shipped mods and their ports use, plus the
//! numeric spacing scale (`p_2`, `gap_1`, …: one unit is 4 px, as in GPUI's
//! `rems(0.25)`).
//!
//! The methods that take an argument are [`PARAM_STYLES`], copied verbatim.
use std::collections::HashMap;
use std::sync::OnceLock;

use taffy::geometry::Point;
use taffy::prelude::*;
use taffy::style::Overflow;

use crate::value::{Bridged, Color};

/// Style methods that take an argument, in the order they are documented.
/// Copied from gpui-kit; the description is what its `.d.ts` shows.
pub const PARAM_STYLES: &[(&str, &str)] = &[
    ("w", "Sets the width."),
    ("h", "Sets the height."),
    ("size", "Sets the width and the height together."),
    ("min_w", "Sets the minimum width."),
    ("min_h", "Sets the minimum height."),
    ("min_size", "Sets the minimum width and height together."),
    ("max_w", "Sets the maximum width."),
    ("max_h", "Sets the maximum height."),
    ("max_size", "Sets the maximum width and height together."),
    ("p", "Sets the padding on all four sides."),
    ("px", "Sets the padding on the left and right."),
    ("py", "Sets the padding on the top and bottom."),
    ("pt", "Sets the padding on the top."),
    ("pb", "Sets the padding on the bottom."),
    ("pl", "Sets the padding on the left."),
    ("pr", "Sets the padding on the right."),
    ("m", "Sets the margin on all four sides."),
    ("mx", "Sets the margin on the left and right."),
    ("my", "Sets the margin on the top and bottom."),
    ("mt", "Sets the margin on the top."),
    ("mb", "Sets the margin on the bottom."),
    ("ml", "Sets the margin on the left."),
    ("mr", "Sets the margin on the right."),
    ("inset", "Sets all four offsets of a positioned element."),
    ("top", "Sets the top offset of a positioned element."),
    ("bottom", "Sets the bottom offset of a positioned element."),
    ("left", "Sets the left offset of a positioned element."),
    ("right", "Sets the right offset of a positioned element."),
    ("gap", "Sets the gap between children on both axes."),
    ("gap_x", "Sets the gap between children along the main axis."),
    ("gap_y", "Sets the gap between children along the cross axis."),
    ("flex_grow", "Sets how much of the free space this child takes."),
    ("flex_shrink", "Sets how readily this child gives space back."),
    ("flex_basis", "Sets the size this child starts from before growing or shrinking."),
    ("bg", "Sets the background colour."),
    ("text_color", "Sets the text colour, which children inherit."),
    ("text_bg", "Sets the background painted behind the text itself."),
    ("text_size", "Sets the font size."),
    ("font_family", "Sets the font family."),
    ("font_weight", "Sets the font weight to a number between 100 and 900."),
    ("line_height", "Sets the line height. A bare number is a multiplier (`1.45`), not pixels; a string is a length."),
    ("opacity", "Sets the opacity of the element and everything in it, from 0 to 1."),
    ("border", "Sets the border width on all four sides. Draws nothing without a colour."),
    ("border_t", "Sets the border width on the top."),
    ("border_b", "Sets the border width on the bottom."),
    ("border_l", "Sets the border width on the left."),
    ("border_r", "Sets the border width on the right."),
    ("border_x", "Sets the border width on the left and right."),
    ("border_y", "Sets the border width on the top and bottom."),
    ("border_color", "Sets the border colour. Draws nothing without a width."),
    ("rounded", "Sets the corner radius on all four corners."),
    ("rounded_t", "Sets the corner radius on the two top corners."),
    ("rounded_b", "Sets the corner radius on the two bottom corners."),
    ("rounded_l", "Sets the corner radius on the two left corners."),
    ("rounded_r", "Sets the corner radius on the two right corners."),
    ("rounded_tl", "Sets the corner radius on the top-left corner."),
    ("rounded_tr", "Sets the corner radius on the top-right corner."),
    ("rounded_bl", "Sets the corner radius on the bottom-left corner."),
    ("rounded_br", "Sets the corner radius on the bottom-right corner."),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum TextAlign {
    #[default]
    Left,
    Center,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum ScrollbarMode {
    /// Only while its thumb is dragged.
    Scrolling,
    /// While the pointer is over the list.
    Hover,
    /// Whenever the content overflows.
    Always,
    /// While the pointer moves over the list or the list scrolls, and for a
    /// moment after: the default.
    #[default]
    Auto,
}

/// What painting needs beyond geometry. Inherited text properties are
/// `Option` so a child can tell "unset" from "set to the default".
#[derive(Clone, Debug, PartialEq)]
pub struct Paint {
    pub background: Option<Color>,
    pub text_color: Option<Color>,
    pub text_size: Option<f32>,
    pub font_weight: Option<u16>,
    pub italic: Option<bool>,
    pub line_height: Option<f32>,
    pub border_color: Option<Color>,
    /// Top-left, top-right, bottom-right, bottom-left.
    pub radius: [f32; 4],
    pub opacity: f32,
    pub grayscale: bool,
    pub truncate: bool,
    pub tooltip_on_truncate: bool,
    pub nowrap: bool,
    pub align: Option<TextAlign>,
    pub cursor_pointer: bool,
    pub cursor_ew_resize: bool,
    pub visible: bool,
    pub overflow_hidden: bool,
    pub scroll_y: bool,
    pub scroll_x: bool,
    pub scrollbar: ScrollbarMode,
}

impl Default for Paint {
    fn default() -> Self {
        Self {
            background: None,
            text_color: None,
            text_size: None,
            font_weight: None,
            italic: None,
            line_height: None,
            border_color: None,
            radius: [0.0; 4],
            opacity: 1.0,
            grayscale: false,
            truncate: false,
            tooltip_on_truncate: false,
            nowrap: false,
            align: None,
            cursor_pointer: false,
            cursor_ew_resize: false,
            visible: true,
            overflow_hidden: false,
            scroll_y: false,
            scroll_x: false,
            scrollbar: ScrollbarMode::Auto,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Style {
    pub layout: taffy::Style,
    pub paint: Paint,
}

impl Default for Style {
    /// A `div()` is a block, as in GPUI; `flex()` opts into flexbox.
    fn default() -> Self {
        Style { layout: taffy::Style { display: Display::Block, ..Default::default() }, paint: Paint::default() }
    }
}

/// The length grammar: a bare number is pixels, `"auto"`, `"50%"`, `"12px"`,
/// `"1rem"` (16 px).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Len {
    Px(f32),
    Percent(f32),
    Auto,
}

fn parse_len(value: &Bridged, name: &str) -> Result<Len, String> {
    match value {
        Bridged::Number(n) if n.is_finite() => Ok(Len::Px(*n as f32)),
        Bridged::Str(s) => {
            let s = s.trim();
            if s == "auto" {
                return Ok(Len::Auto);
            }
            if let Some(p) = s.strip_suffix('%') {
                return p.parse::<f32>().map(|p| Len::Percent(p / 100.0)).map_err(|_| format!("{name}: invalid percentage {s:?}"));
            }
            if let Some(px) = s.strip_suffix("px") {
                return px.parse::<f32>().map(Len::Px).map_err(|_| format!("{name}: invalid length {s:?}"));
            }
            if let Some(rem) = s.strip_suffix("rem") {
                return rem.parse::<f32>().map(|r| Len::Px(r * 16.0)).map_err(|_| format!("{name}: invalid length {s:?}"));
            }
            s.parse::<f32>().map(Len::Px).map_err(|_| format!("{name}: invalid length {s:?}"))
        }
        other => Err(format!("{name}: expected a number or a length string, got {other:?}")),
    }
}

fn dimension(len: Len) -> Dimension {
    match len {
        Len::Px(v) => length(v),
        Len::Percent(p) => percent(p),
        Len::Auto => auto(),
    }
}

fn lpa(len: Len) -> LengthPercentageAuto {
    match len {
        Len::Px(v) => length(v),
        Len::Percent(p) => percent(p),
        Len::Auto => auto(),
    }
}

fn lp(len: Len, name: &str) -> Result<LengthPercentage, String> {
    match len {
        Len::Px(v) => Ok(length(v)),
        Len::Percent(p) => Ok(percent(p)),
        Len::Auto => Err(format!("{name}: auto is not allowed here")),
    }
}

fn px_only(len: Len, name: &str) -> Result<f32, String> {
    match len {
        Len::Px(v) => Ok(v),
        _ => Err(format!("{name}: expected a pixel length")),
    }
}

fn number(value: &Bridged, name: &str) -> Result<f32, String> {
    value.as_f32().ok_or_else(|| format!("{name}: expected a number"))
}

fn color(value: &Bridged, name: &str, palette: &HashMap<String, Color>) -> Result<Color, String> {
    let text = value.as_str().ok_or_else(|| format!("{name}: expected a colour string"))?;
    Color::parse(text, palette).ok_or_else(|| format!("{name}: unknown colour {text:?}"))
}

/// Applies a style method that takes an argument. Copied from gpui-kit's
/// `apply_param`, with GPUI's `StyleRefinement` replaced by [`Style`].
pub fn apply_param(name: &str, value: &Bridged, style: &mut Style, palette: &HashMap<String, Color>) -> Result<(), String> {
    let l = &mut style.layout;
    let p = &mut style.paint;
    match name {
        "w" => l.size.width = dimension(parse_len(value, name)?),
        "h" => l.size.height = dimension(parse_len(value, name)?),
        "size" => {
            let d = dimension(parse_len(value, name)?);
            l.size = Size { width: d, height: d };
        }
        "min_w" => l.min_size.width = lpa(parse_len(value, name)?),
        "min_h" => l.min_size.height = lpa(parse_len(value, name)?),
        "min_size" => {
            let d = lpa(parse_len(value, name)?);
            l.min_size = Size { width: d, height: d };
        }
        "max_w" => l.max_size.width = lpa(parse_len(value, name)?),
        "max_h" => l.max_size.height = lpa(parse_len(value, name)?),
        "max_size" => {
            let d = lpa(parse_len(value, name)?);
            l.max_size = Size { width: d, height: d };
        }
        "p" => {
            let v = lp(parse_len(value, name)?, name)?;
            l.padding = Rect { left: v, right: v, top: v, bottom: v };
        }
        "px" => {
            let v = lp(parse_len(value, name)?, name)?;
            l.padding.left = v;
            l.padding.right = v;
        }
        "py" => {
            let v = lp(parse_len(value, name)?, name)?;
            l.padding.top = v;
            l.padding.bottom = v;
        }
        "pt" => l.padding.top = lp(parse_len(value, name)?, name)?,
        "pb" => l.padding.bottom = lp(parse_len(value, name)?, name)?,
        "pl" => l.padding.left = lp(parse_len(value, name)?, name)?,
        "pr" => l.padding.right = lp(parse_len(value, name)?, name)?,
        "m" => {
            let v = lpa(parse_len(value, name)?);
            l.margin = Rect { left: v, right: v, top: v, bottom: v };
        }
        "mx" => {
            let v = lpa(parse_len(value, name)?);
            l.margin.left = v;
            l.margin.right = v;
        }
        "my" => {
            let v = lpa(parse_len(value, name)?);
            l.margin.top = v;
            l.margin.bottom = v;
        }
        "mt" => l.margin.top = lpa(parse_len(value, name)?),
        "mb" => l.margin.bottom = lpa(parse_len(value, name)?),
        "ml" => l.margin.left = lpa(parse_len(value, name)?),
        "mr" => l.margin.right = lpa(parse_len(value, name)?),
        "inset" => {
            let v = lpa(parse_len(value, name)?);
            l.inset = Rect { left: v, right: v, top: v, bottom: v };
        }
        "top" => l.inset.top = lpa(parse_len(value, name)?),
        "bottom" => l.inset.bottom = lpa(parse_len(value, name)?),
        "left" => l.inset.left = lpa(parse_len(value, name)?),
        "right" => l.inset.right = lpa(parse_len(value, name)?),
        "gap" => {
            let v = lp(parse_len(value, name)?, name)?;
            l.gap = Size { width: v, height: v };
        }
        "gap_x" => l.gap.width = lp(parse_len(value, name)?, name)?,
        "gap_y" => l.gap.height = lp(parse_len(value, name)?, name)?,
        "flex_grow" => l.flex_grow = number(value, name)?,
        "flex_shrink" => l.flex_shrink = number(value, name)?,
        "flex_basis" => l.flex_basis = dimension(parse_len(value, name)?),
        "bg" => p.background = Some(color(value, name, palette)?),
        "text_color" => p.text_color = Some(color(value, name, palette)?),
        // Painted behind glyphs in GPUI; the nearest thing here is the element's own background.
        "text_bg" => p.background = Some(color(value, name, palette)?),
        "text_size" => p.text_size = Some(px_only(parse_len(value, name)?, name)?),
            "font_family" => {} // Accept this for ported mods. The frontend chooses the UI font.
        "font_weight" => {
            let w = number(value, name)?;
            if !(100.0..=900.0).contains(&w) {
                return Err(format!("{name}: expected 100..=900"));
            }
            p.font_weight = Some(w as u16);
        }
        "line_height" => {
            p.line_height = Some(match value {
                Bridged::Number(n) => (*n as f32) * p.text_size.unwrap_or(DEFAULT_TEXT_SIZE),
                other => px_only(parse_len(other, name)?, name)?,
            })
        }
        "opacity" => p.opacity = number(value, name)?.clamp(0.0, 1.0),
        "border" => {
            let v = px_only(parse_len(value, name)?, name)?;
            l.border = Rect { left: length(v), right: length(v), top: length(v), bottom: length(v) };
        }
        "border_t" => l.border.top = length(px_only(parse_len(value, name)?, name)?),
        "border_b" => l.border.bottom = length(px_only(parse_len(value, name)?, name)?),
        "border_l" => l.border.left = length(px_only(parse_len(value, name)?, name)?),
        "border_r" => l.border.right = length(px_only(parse_len(value, name)?, name)?),
        "border_x" => {
            let v = length(px_only(parse_len(value, name)?, name)?);
            l.border.left = v;
            l.border.right = v;
        }
        "border_y" => {
            let v = length(px_only(parse_len(value, name)?, name)?);
            l.border.top = v;
            l.border.bottom = v;
        }
        "border_color" => p.border_color = Some(color(value, name, palette)?),
        "rounded" => p.radius = [px_only(parse_len(value, name)?, name)?; 4],
        "rounded_t" => {
            let v = px_only(parse_len(value, name)?, name)?;
            p.radius[0] = v;
            p.radius[1] = v;
        }
        "rounded_b" => {
            let v = px_only(parse_len(value, name)?, name)?;
            p.radius[2] = v;
            p.radius[3] = v;
        }
        "rounded_l" => {
            let v = px_only(parse_len(value, name)?, name)?;
            p.radius[0] = v;
            p.radius[3] = v;
        }
        "rounded_r" => {
            let v = px_only(parse_len(value, name)?, name)?;
            p.radius[1] = v;
            p.radius[2] = v;
        }
        "rounded_tl" => p.radius[0] = px_only(parse_len(value, name)?, name)?,
        "rounded_tr" => p.radius[1] = px_only(parse_len(value, name)?, name)?,
        "rounded_br" => p.radius[2] = px_only(parse_len(value, name)?, name)?,
        "rounded_bl" => p.radius[3] = px_only(parse_len(value, name)?, name)?,
        other => return Err(unknown_message(other)),
    }
    Ok(())
}

pub const DEFAULT_TEXT_SIZE: f32 = 14.0;

type NullaryFn = fn(&mut Style);

/// No-argument style methods: the hand-written half of the surface.
const NULLARY_FIXED: &[(&str, NullaryFn)] = &[
    // Display and flex.
    ("flex", |s| s.layout.display = Display::Flex),
    ("block", |s| s.layout.display = Display::Block),
    ("hidden", |s| s.layout.display = Display::None),
    ("visible", |s| s.paint.visible = true),
    ("invisible", |s| s.paint.visible = false),
    ("grayscale", |s| s.paint.grayscale = true),
    ("flex_row", |s| s.layout.flex_direction = FlexDirection::Row),
    ("flex_col", |s| s.layout.flex_direction = FlexDirection::Column),
    ("flex_row_reverse", |s| s.layout.flex_direction = FlexDirection::RowReverse),
    ("flex_col_reverse", |s| s.layout.flex_direction = FlexDirection::ColumnReverse),
    ("flex_wrap", |s| s.layout.flex_wrap = FlexWrap::Wrap),
    ("flex_nowrap", |s| s.layout.flex_wrap = FlexWrap::NoWrap),
    ("flex_1", |s| {
        s.layout.flex_grow = 1.0;
        s.layout.flex_shrink = 1.0;
        s.layout.flex_basis = percent(0.0);
    }),
    ("flex_auto", |s| {
        s.layout.flex_grow = 1.0;
        s.layout.flex_shrink = 1.0;
        s.layout.flex_basis = auto();
    }),
    ("flex_initial", |s| {
        s.layout.flex_grow = 0.0;
        s.layout.flex_shrink = 1.0;
        s.layout.flex_basis = auto();
    }),
    ("flex_none", |s| {
        s.layout.flex_grow = 0.0;
        s.layout.flex_shrink = 0.0;
    }),
    ("flex_grow", |s| s.layout.flex_grow = 1.0),
    ("flex_shrink", |s| s.layout.flex_shrink = 1.0),
    ("flex_shrink_0", |s| s.layout.flex_shrink = 0.0),
    ("items_start", |s| s.layout.align_items = AlignItems::FLEX_START),
    ("items_center", |s| s.layout.align_items = AlignItems::CENTER),
    ("items_end", |s| s.layout.align_items = AlignItems::FLEX_END),
    ("items_baseline", |s| s.layout.align_items = AlignItems::BASELINE),
    ("items_stretch", |s| s.layout.align_items = AlignItems::STRETCH),
    ("justify_start", |s| s.layout.justify_content = JustifyContent::FLEX_START),
    ("justify_center", |s| s.layout.justify_content = JustifyContent::CENTER),
    ("justify_end", |s| s.layout.justify_content = JustifyContent::FLEX_END),
    ("justify_between", |s| s.layout.justify_content = JustifyContent::SPACE_BETWEEN),
    ("justify_around", |s| s.layout.justify_content = JustifyContent::SPACE_AROUND),
    ("justify_evenly", |s| s.layout.justify_content = JustifyContent::SPACE_EVENLY),
    ("content_start", |s| s.layout.align_content = AlignContent::FLEX_START),
    ("content_center", |s| s.layout.align_content = AlignContent::CENTER),
    ("content_end", |s| s.layout.align_content = AlignContent::FLEX_END),
    ("self_start", |s| s.layout.align_self = Some(AlignSelf::FLEX_START)),
    ("self_center", |s| s.layout.align_self = Some(AlignSelf::CENTER)),
    ("self_end", |s| s.layout.align_self = Some(AlignSelf::FLEX_END)),
    ("self_stretch", |s| s.layout.align_self = Some(AlignSelf::STRETCH)),
    // Sizes.
    ("size_full", |s| s.layout.size = Size { width: percent(1.0), height: percent(1.0) }),
    ("w_full", |s| s.layout.size.width = percent(1.0)),
    ("h_full", |s| s.layout.size.height = percent(1.0)),
    ("w_auto", |s| s.layout.size.width = auto()),
    ("h_auto", |s| s.layout.size.height = auto()),
    ("min_w_0", |s| s.layout.min_size.width = length(0.0)),
    ("min_h_0", |s| s.layout.min_size.height = length(0.0)),
    ("min_w_full", |s| s.layout.min_size.width = percent(1.0)),
    ("min_h_full", |s| s.layout.min_size.height = percent(1.0)),
    ("max_w_full", |s| s.layout.max_size.width = percent(1.0)),
    ("max_h_full", |s| s.layout.max_size.height = percent(1.0)),
    // Position.
    ("relative", |s| s.layout.position = Position::Relative),
    ("absolute", |s| s.layout.position = Position::Absolute),
    ("inset_0", |s| s.layout.inset = Rect { left: length(0.0), right: length(0.0), top: length(0.0), bottom: length(0.0) }),
    ("top_0", |s| s.layout.inset.top = length(0.0)),
    ("bottom_0", |s| s.layout.inset.bottom = length(0.0)),
    ("left_0", |s| s.layout.inset.left = length(0.0)),
    ("right_0", |s| s.layout.inset.right = length(0.0)),
    // Overflow and scrolling.
    ("overflow_hidden", |s| {
        s.paint.overflow_hidden = true;
        s.layout.overflow = Point { x: Overflow::Hidden, y: Overflow::Hidden };
    }),
    ("overflow_x_hidden", |s| {
        s.paint.overflow_hidden = true;
        s.layout.overflow.x = Overflow::Hidden;
    }),
    ("overflow_y_hidden", |s| {
        s.paint.overflow_hidden = true;
        s.layout.overflow.y = Overflow::Hidden;
    }),
    ("overflow_y_scroll", scroll_y),
    ("overflow_y_scrollbar", scroll_y),
    ("overflow_x_scroll", scroll_x),
    ("overflow_x_scrollbar", scroll_x),
    ("overflow_scroll", scroll_y),
    ("overflow_scrollbar", scroll_y),
    // Text.
    ("truncate", |s| {
        s.paint.truncate = true;
        s.paint.nowrap = true;
        s.paint.overflow_hidden = true;
        s.layout.overflow = Point { x: Overflow::Hidden, y: Overflow::Hidden };
    }),
    ("tooltip_on_truncate", |s| s.paint.tooltip_on_truncate = true),
    ("text_ellipsis", |s| s.paint.truncate = true),
    ("whitespace_nowrap", |s| s.paint.nowrap = true),
    ("whitespace_normal", |s| s.paint.nowrap = false),
    ("text_left", |s| s.paint.align = Some(TextAlign::Left)),
    ("text_center", |s| s.paint.align = Some(TextAlign::Center)),
    ("text_right", |s| s.paint.align = Some(TextAlign::Right)),
    ("text_xs", |s| s.paint.text_size = Some(12.0)),
    ("text_sm", |s| s.paint.text_size = Some(14.0)),
    ("text_base", |s| s.paint.text_size = Some(16.0)),
    ("text_lg", |s| s.paint.text_size = Some(18.0)),
    ("text_xl", |s| s.paint.text_size = Some(20.0)),
    ("text_2xl", |s| s.paint.text_size = Some(24.0)),
    ("text_3xl", |s| s.paint.text_size = Some(30.0)),
    ("italic", |s| s.paint.italic = Some(true)),
    ("not_italic", |s| s.paint.italic = Some(false)),
    ("font_thin", |s| s.paint.font_weight = Some(100)),
    ("font_extralight", |s| s.paint.font_weight = Some(200)),
    ("font_light", |s| s.paint.font_weight = Some(300)),
    ("font_normal", |s| s.paint.font_weight = Some(400)),
    ("font_medium", |s| s.paint.font_weight = Some(500)),
    ("font_semibold", |s| s.paint.font_weight = Some(600)),
    ("font_bold", |s| s.paint.font_weight = Some(700)),
    ("font_extrabold", |s| s.paint.font_weight = Some(800)),
    ("font_black", |s| s.paint.font_weight = Some(900)),
    // Cursor.
    ("cursor_pointer", |s| s.paint.cursor_pointer = true),
    ("cursor_default", |s| { s.paint.cursor_pointer = false; s.paint.cursor_ew_resize = false; }),
    ("cursor_ew_resize", |s| s.paint.cursor_ew_resize = true),
    // Borders and corners.
    ("border_0", |s| s.layout.border = Rect { left: length(0.0), right: length(0.0), top: length(0.0), bottom: length(0.0) }),
    ("border_1", |s| s.layout.border = Rect { left: length(1.0), right: length(1.0), top: length(1.0), bottom: length(1.0) }),
    ("border_2", |s| s.layout.border = Rect { left: length(2.0), right: length(2.0), top: length(2.0), bottom: length(2.0) }),
    ("border_t_1", |s| s.layout.border.top = length(1.0)),
    ("border_b_1", |s| s.layout.border.bottom = length(1.0)),
    ("border_l_1", |s| s.layout.border.left = length(1.0)),
    ("border_r_1", |s| s.layout.border.right = length(1.0)),
    ("rounded_none", |s| s.paint.radius = [0.0; 4]),
    ("rounded_sm", |s| s.paint.radius = [2.0; 4]),
    ("rounded_md", |s| s.paint.radius = [4.0; 4]),
    ("rounded_lg", |s| s.paint.radius = [8.0; 4]),
    ("rounded_xl", |s| s.paint.radius = [12.0; 4]),
    ("rounded_2xl", |s| s.paint.radius = [16.0; 4]),
    ("rounded_full", |s| s.paint.radius = [9999.0; 4]),
    // Shadows have no native primitive here; accepted so ports keep compiling.
    ("shadow_sm", |_| {}),
    ("shadow_md", |_| {}),
    ("shadow_lg", |_| {}),
    ("shadow_xl", |_| {}),
    ("shadow_none", |_| {}),
];

fn scroll_y(s: &mut Style) {
    s.paint.scroll_y = true;
    s.paint.overflow_hidden = true;
    s.layout.overflow = Point { x: if s.paint.scroll_x { Overflow::Scroll } else { Overflow::Hidden }, y: Overflow::Scroll };
    s.layout.scrollbar_width = 0.0;
}

/// Sideways scrolling, with the same rubber band, fling and scrollbar as a
/// vertical list.
fn scroll_x(s: &mut Style) {
    s.paint.scroll_x = true;
    s.paint.overflow_hidden = true;
    s.layout.overflow = Point { x: Overflow::Scroll, y: if s.paint.scroll_y { Overflow::Scroll } else { Overflow::Hidden } };
    s.layout.scrollbar_width = 0.0;
}

/// GPUI's spacing scale: the suffix after the underscore, and its pixels.
const SCALE: &[(&str, f32)] = &[
    ("0", 0.0),
    ("0p5", 2.0),
    ("1", 4.0),
    ("1p5", 6.0),
    ("2", 8.0),
    ("2p5", 10.0),
    ("3", 12.0),
    ("3p5", 14.0),
    ("4", 16.0),
    ("5", 20.0),
    ("6", 24.0),
    ("7", 28.0),
    ("8", 32.0),
    ("9", 36.0),
    ("10", 40.0),
    ("11", 44.0),
    ("12", 48.0),
    ("14", 56.0),
    ("16", 64.0),
    ("20", 80.0),
    ("24", 96.0),
    ("28", 112.0),
    ("32", 128.0),
    ("36", 144.0),
    ("40", 160.0),
    ("44", 176.0),
    ("48", 192.0),
    ("56", 224.0),
    ("64", 256.0),
    ("72", 288.0),
    ("80", 320.0),
    ("96", 384.0),
];

const SCALED: &[&str] = &[
    "p", "px", "py", "pt", "pb", "pl", "pr", "m", "mx", "my", "mt", "mb", "ml", "mr", "gap", "gap_x", "gap_y", "w", "h", "size", "min_w", "min_h",
    "max_w", "max_h", "top", "bottom", "left", "right", "inset",
];

enum Nullary {
    Fixed(NullaryFn),
    Scaled(&'static str, f32),
}

struct Table {
    entries: Vec<(&'static str, Nullary)>,
    by_name: HashMap<&'static str, u16>,
}

fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut entries: Vec<(&'static str, Nullary)> = NULLARY_FIXED.iter().map(|(name, f)| (*name, Nullary::Fixed(*f))).collect();
        for base in SCALED {
            for (suffix, px) in SCALE {
                // Leaked once per process: these are the method names the prelude binds.
                let name: &'static str = Box::leak(format!("{base}_{suffix}").into_boxed_str());
                entries.push((name, Nullary::Scaled(base, *px)));
            }
        }
        let mut by_name = HashMap::with_capacity(entries.len());
        for (index, (name, _)) in entries.iter().enumerate() {
            by_name.entry(*name).or_insert(index as u16);
        }
        Table { entries, by_name }
    })
}

/// Index of a no-argument style method, if the name is one.
pub fn nullary_index(name: &str) -> Option<u16> {
    table().by_name.get(name).copied()
}

/// Every no-argument style name with the index that records it, sorted.
pub fn nullary_styles() -> Vec<(&'static str, u16)> {
    let mut named: Vec<_> = table().by_name.iter().map(|(name, index)| (*name, *index)).collect();
    named.sort_unstable();
    named
}

pub fn nullary_name(index: u16) -> &'static str {
    table().entries.get(index as usize).map_or("<unknown style>", |(name, _)| *name)
}

pub fn param_style_name(name: &str) -> Option<&'static str> {
    PARAM_STYLES.iter().find(|(candidate, _)| *candidate == name).map(|(name, _)| *name)
}

pub fn param_style_at(index: usize) -> Option<&'static str> {
    PARAM_STYLES.get(index).map(|(name, _)| *name)
}

pub fn apply_nullary(index: u16, style: &mut Style, palette: &HashMap<String, Color>) {
    match table().entries.get(index as usize) {
        Some((_, Nullary::Fixed(apply))) => apply(style),
        Some((_, Nullary::Scaled(base, px))) => {
            let _ = apply_param(base, &Bridged::Number(f64::from(*px)), style, palette);
        }
        None => {}
    }
}

pub fn known_names() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = table().entries.iter().map(|(name, _)| *name).chain(PARAM_STYLES.iter().map(|(name, _)| *name)).collect();
    names.sort_unstable();
    names
}

/// The closest known style method name, for "did you mean" errors. Copied
/// from gpui-kit: a wrong suggestion is worse than none, so the budget is tight.
pub fn suggest(name: &str) -> Option<&'static str> {
    let budget = 2.max(name.chars().count() / 3);
    let mut best: Option<(usize, &'static str)> = None;
    for candidate in known_names() {
        let distance = edit_distance(name, candidate);
        if distance > budget {
            continue;
        }
        if best.is_none_or(|(best_distance, _)| distance < best_distance) {
            best = Some((distance, candidate));
        }
    }
    best.map(|(_, candidate)| candidate)
}

pub fn unknown_message(name: &str) -> String {
    match suggest(name) {
        Some(candidate) => format!("unknown style method {name:?}; did you mean {candidate:?}?"),
        None => format!("unknown style method {name:?}"),
    }
}

fn edit_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut current = vec![i + 1];
        for (j, cb) in b.iter().enumerate() {
            let cost = usize::from(ca != cb);
            current.push((previous[j] + cost).min(previous[j + 1] + 1).min(current[j] + 1));
        }
        previous = current;
    }
    previous[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scaled_names_resolve_to_pixels() {
        let palette = HashMap::new();
        let mut style = Style::default();
        apply_nullary(nullary_index("p_2").unwrap(), &mut style, &palette);
        assert_eq!(style.layout.padding.left, length(8.0));
        apply_nullary(nullary_index("gap_1p5").unwrap(), &mut style, &palette);
        assert_eq!(style.layout.gap.width, length(6.0));
        apply_nullary(nullary_index("flex_1").unwrap(), &mut style, &palette);
        assert_eq!(style.layout.flex_grow, 1.0);
    }

    #[test]
    fn param_grammar_accepts_numbers_percentages_and_auto() {
        let palette = HashMap::new();
        let mut style = Style::default();
        apply_param("w", &Bridged::Str("50%".into()), &mut style, &palette).unwrap();
        assert_eq!(style.layout.size.width, percent(0.5));
        apply_param("h", &Bridged::Str("auto".into()), &mut style, &palette).unwrap();
        assert_eq!(style.layout.size.height, auto());
        apply_param("rounded", &Bridged::Number(8.0), &mut style, &palette).unwrap();
        assert_eq!(style.paint.radius, [8.0; 4]);
        assert!(apply_param("p", &Bridged::Str("auto".into()), &mut style, &palette).is_err());
        assert!(apply_param("bg", &Bridged::Str("#20212".into()), &mut style, &palette).is_err());
    }

    #[test]
    fn typos_get_a_suggestion() {
        assert_eq!(suggest("items_centre"), Some("items_center"));
        assert_eq!(suggest("zzzzzzzzzz"), None);
        assert!(unknown_message("flex_col_").contains("flex_col"));
    }
}
