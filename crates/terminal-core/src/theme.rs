//! Shared colour defaults and owner-only OSC / colour-scheme query state.
use crate::{
    Error,
    vt::{
        Terminal,
        style::{Palette, RgbColor},
        terminal::{ColorScheme as VtScheme, Mode},
    },
};
pub use graffitty_protocol::terminal_theme::{ColorScheme, Theme};
use std::{cell::Cell, rc::Rc};

pub fn rgb([r, g, b]: [u8; 3]) -> RgbColor {
    RgbColor { r, g, b }
}
pub fn bytes(c: RgbColor) -> [u8; 3] {
    [c.r, c.g, c.b]
}

/// Capture defaults, never application overrides. Unset defaults render as
/// white on black in libghostty; OSC queries must report those, not go unanswered.
pub fn defaults(vt: &Terminal<'_, '_>) -> Result<Theme, Error> {
    let foreground = vt.default_fg_color()?.map(bytes).unwrap_or([255; 3]);
    let background = vt.default_bg_color()?.map(bytes).unwrap_or([0; 3]);
    Ok(Theme {
        foreground,
        background,
        cursor: vt.default_cursor_color()?.map(bytes).unwrap_or(foreground),
        scheme: scheme(background),
        palette: vt
            .default_color_palette()?
            .0
            .into_iter()
            .map(bytes)
            .collect(),
    })
}

pub fn scheme(background: [u8; 3]) -> ColorScheme {
    let linear = background.map(|v| {
        let v = f64::from(v) / 255.;
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    });
    if linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722 < 0.179 {
        ColorScheme::Dark
    } else {
        ColorScheme::Light
    }
}

/// Set host defaults via the VT API, not OSC (which would pin application
/// overrides). Validate the whole document before changing any terminal state.
pub fn apply(vt: &mut Terminal<'_, '_>, theme: &Theme) -> Result<(), Error> {
    if theme.palette.len() != 256 {
        return Err("Terminal theme requires 256 palette colors".into());
    }
    let palette = std::array::from_fn(|i| rgb(theme.palette[i]));
    vt.set_default_fg_color(Some(rgb(theme.foreground)))?
        .set_default_bg_color(Some(rgb(theme.background)))?
        .set_default_cursor_color(Some(rgb(theme.cursor)))?
        .set_default_color_palette(Some(Palette(palette)))?;
    Ok(())
}

/// One query authority per PTY. The latest displayed frontend theme remains
/// valid while detached. Mirrors must not send these replies themselves.
pub struct Queries {
    theme: Theme,
    scheme: Rc<Cell<VtScheme>>,
}
impl Queries {
    pub fn new(vt: &mut Terminal<'_, '_>) -> Result<Self, Error> {
        let theme = defaults(vt)?;
        apply(vt, &theme)?;
        let scheme = Rc::new(Cell::new(vt_scheme(theme.scheme)));
        let current = scheme.clone();
        vt.on_color_scheme(move |_| Some(current.get()))?;
        Ok(Self { theme, scheme })
    }

    pub fn theme(&self) -> &Theme {
        &self.theme
    }

    /// Return an unsolicited report only when the application enabled mode
    /// 2031. Same-scheme palette/background changes also need a re-query.
    pub fn update(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        theme: Theme,
    ) -> Result<Option<&'static [u8]>, Error> {
        if self.theme == theme {
            return Ok(None);
        }
        apply(vt, &theme)?;
        self.scheme.set(vt_scheme(theme.scheme));
        self.theme = theme;
        Ok(vt
            .mode(Mode::COLOR_SCHEME_REPORT)?
            .then_some(match self.theme.scheme {
                ColorScheme::Dark => b"\x1b[?997;1n".as_slice(),
                ColorScheme::Light => b"\x1b[?997;2n".as_slice(),
            }))
    }
}
fn vt_scheme(scheme: ColorScheme) -> VtScheme {
    match scheme {
        ColorScheme::Dark => VtScheme::Dark,
        ColorScheme::Light => VtScheme::Light,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn terminal() -> (Terminal<'static, 'static>, Rc<RefCell<Vec<u8>>>) {
        let mut vt = crate::new_vt(80, 24, 0).unwrap();
        let replies = Rc::new(RefCell::new(Vec::new()));
        let captured = replies.clone();
        vt.on_pty_write(move |_, bytes| captured.borrow_mut().extend_from_slice(bytes))
            .unwrap();
        (vt, replies)
    }
    fn query(vt: &mut Terminal<'_, '_>, replies: &RefCell<Vec<u8>>, request: &[u8]) -> String {
        replies.borrow_mut().clear();
        vt.vt_write(request);
        String::from_utf8(replies.borrow().clone()).unwrap()
    }
    fn osc(index: &str, rgb: &str) -> String {
        format!("\x1b]{index};rgb:{rgb}\x07")
    }
    fn displayed(vt: &Terminal<'_, '_>) -> Theme {
        let mut theme = defaults(vt).unwrap();
        theme.foreground = [255; 3];
        theme.background = [40, 44, 52];
        theme.cursor = [195, 151, 216];
        theme.palette[2] = [181, 189, 104];
        theme.palette[200] = [18, 52, 86];
        theme
    }

    #[test]
    fn pi_queries_report_the_displayed_background_foreground_cursor_and_palette() {
        let (mut vt, replies) = terminal();
        let mut owner = Queries::new(&mut vt).unwrap();
        let theme = displayed(&vt);
        assert_eq!(owner.update(&mut vt, theme.clone()).unwrap(), None);
        assert_eq!(
            query(
                &mut vt,
                &replies,
                b"\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07\x1b]4;2;?;200;?\x07"
            ),
            osc("10", "ffff/ffff/ffff")
                + &osc("11", "2828/2c2c/3434")
                + &osc("12", "c3c3/9797/d8d8")
                + &osc("4;2", "b5b5/bdbd/6868")
                + &osc("4;200", "1212/3434/5656")
        );
        assert_eq!(defaults(&vt).unwrap(), theme);
    }

    #[test]
    fn application_overrides_survive_theme_changes_and_resets_use_new_defaults() {
        let (mut vt, replies) = terminal();
        let mut owner = Queries::new(&mut vt).unwrap();
        vt.vt_write(
            b"\x1b]10;#112233\x07\x1b]11;#445566\x07\x1b]12;#778899\x07\x1b]4;2;#abcdef\x07",
        );
        let theme = displayed(&vt);
        owner.update(&mut vt, theme.clone()).unwrap();
        let request = b"\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07\x1b]4;2;?\x07";
        assert_eq!(
            query(&mut vt, &replies, request),
            osc("10", "1111/2222/3333")
                + &osc("11", "4444/5555/6666")
                + &osc("12", "7777/8888/9999")
                + &osc("4;2", "abab/cdcd/efef")
        );
        assert_eq!(
            defaults(&vt).unwrap(),
            theme,
            "Do not publish application overrides as frontend defaults"
        );
        vt.vt_write(b"\x1b]110\x07\x1b]111\x07\x1b]112\x07\x1b]104;2\x07");
        assert_eq!(
            query(&mut vt, &replies, request),
            osc("10", "ffff/ffff/ffff")
                + &osc("11", "2828/2c2c/3434")
                + &osc("12", "c3c3/9797/d8d8")
                + &osc("4;2", "b5b5/bdbd/6868")
        );
    }

    #[test]
    fn theme_notifications_are_opt_in_deduplicated_and_include_same_scheme_changes() {
        let (mut vt, replies) = terminal();
        let mut owner = Queries::new(&mut vt).unwrap();
        let mut theme = displayed(&vt);
        assert_eq!(owner.update(&mut vt, theme.clone()).unwrap(), None);
        vt.vt_write(b"\x1b[?2031h");
        assert_eq!(owner.update(&mut vt, theme.clone()).unwrap(), None);
        theme.background = [50, 54, 62];
        assert_eq!(
            owner.update(&mut vt, theme.clone()).unwrap(),
            Some(b"\x1b[?997;1n".as_slice())
        );
        theme.palette[2] = [10, 200, 20];
        assert_eq!(
            owner.update(&mut vt, theme.clone()).unwrap(),
            Some(b"\x1b[?997;1n".as_slice())
        );
        theme.background = [250; 3];
        theme.scheme = ColorScheme::Light;
        assert_eq!(
            owner.update(&mut vt, theme.clone()).unwrap(),
            Some(b"\x1b[?997;2n".as_slice())
        );
        assert_eq!(query(&mut vt, &replies, b"\x1b[?996n"), "\x1b[?997;2n");
        vt.vt_write(b"\x1b[?2031l");
        theme.cursor = [0; 3];
        assert_eq!(owner.update(&mut vt, theme).unwrap(), None);
    }

    #[test]
    fn theme_changes_preserve_truecolor_cells_and_checkpoint_keeps_defaults_unpinned() {
        let (mut vt, _) = terminal();
        let mut owner = Queries::new(&mut vt).unwrap();
        vt.vt_write(b"\x1b[38;2;18;52;86m\x1b[48;2;101;67;33mX\x1b[0m");
        let theme = displayed(&vt);
        owner.update(&mut vt, theme).unwrap();
        let frame = crate::screen::snapshot(&vt, 80, 24, false).unwrap();
        assert_eq!(frame.lines[0][0].3, "#123456");
        assert_eq!(frame.lines[0][0].4, "#654321");
        let checkpoint = crate::checkpoint::capture_frontend(&mut vt).unwrap();
        let (mut mirror, replies) = terminal();
        let mut different = displayed(&mirror);
        different.background = [240; 3];
        apply(&mut mirror, &different).unwrap();
        mirror.vt_write(&checkpoint);
        assert_eq!(
            query(&mut mirror, &replies, b"\x1b]11;?\x07"),
            osc("11", "f0f0/f0f0/f0f0")
        );
    }

    #[test]
    fn invalid_palette_cannot_partially_update_query_defaults() {
        let (mut vt, _) = terminal();
        let mut owner = Queries::new(&mut vt).unwrap();
        let before = defaults(&vt).unwrap();
        let mut theme = displayed(&vt);
        theme.palette.pop();
        assert!(owner.update(&mut vt, theme).is_err());
        assert_eq!(defaults(&vt).unwrap(), before);
        assert_eq!(owner.theme(), &before);
    }
}
