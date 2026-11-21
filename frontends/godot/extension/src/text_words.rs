//! Terminal word and line selection for read-only text views.
use godot::prelude::*;
use graffitty_terminal_core::text_words;

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct TextWords {
    base: Base<RefCounted>,
    boundaries: Vec<char>,
}

#[godot_api]
impl IRefCounted for TextWords {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, boundaries: text_words::DEFAULT_WORD_BOUNDARIES.to_vec() }
    }
}

fn span(values: &PackedInt32Array) -> Option<(text_words::Position, text_words::Position)> {
    let v = values.as_slice();
    (v.len() == 4 && v.iter().all(|&n| n >= 0)).then(|| ((v[0] as usize, v[1] as usize), (v[2] as usize, v[3] as usize)))
}

#[godot_api]
impl TextWords {
    /// The terminal's `selection_word_boundaries`; null restores Ghostty's.
    #[func]
    fn set_word_boundaries(&mut self, boundaries: Variant) {
        self.boundaries = match boundaries.try_to::<GString>() {
            Ok(chars) => chars.to_string().chars().collect(),
            Err(_) => text_words::DEFAULT_WORD_BOUNDARIES.to_vec(),
        };
    }

    /// The word around `column` as (start, end) columns.
    #[func]
    fn word_range(&self, line: GString, column: i64) -> Vector2i {
        let chars: Vec<char> = line.to_string().chars().collect();
        let (start, end) = text_words::word_range(&chars, column.max(0) as usize, &self.boundaries);
        Vector2i::new(start as i32, end as i32)
    }

    /// The line without its surrounding blanks, as (start, end) columns.
    #[func]
    fn line_range(&self, line: GString) -> Vector2i {
        let chars: Vec<char> = line.to_string().chars().collect();
        let (start, end) = text_words::line_range(&chars);
        Vector2i::new(start as i32, end as i32)
    }

    /// Spans are `[from_line, from_column, to_line, to_column]`; returns the
    /// selection covering both, or an empty array for malformed spans.
    #[func]
    fn extend(&self, anchor: PackedInt32Array, current: PackedInt32Array) -> PackedInt32Array {
        let (Some(anchor), Some(current)) = (span(&anchor), span(&current)) else {
            return PackedInt32Array::new();
        };
        let ((l0, c0), (l1, c1)) = text_words::extend(anchor, current);
        PackedInt32Array::from(&[l0 as i32, c0 as i32, l1 as i32, c1 as i32][..])
    }
}
