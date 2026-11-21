//! Desktop logical scaling. XRandR millimeters describe hardware, not the
//! user's desktop settings. GNOME publishes text zoom inside its Xft DPI.
fn positive(value: Option<&str>) -> Option<f64> {
    value?
        .trim()
        .parse::<f64>()
        .ok()
        .filter(|n| n.is_finite() && *n > 0.0)
}

fn scale(
    gdk: Option<&str>,
    gdk_dpi: Option<&str>,
    qt: Option<&str>,
    desktop: impl FnOnce() -> f64,
) -> f64 {
    let gdk = positive(gdk);
    let gdk_dpi = positive(gdk_dpi);
    if gdk.is_some() || gdk_dpi.is_some() {
        return gdk.unwrap_or(1.0) * gdk_dpi.unwrap_or(1.0);
    }
    desktop() * positive(qt).unwrap_or(1.0)
}

#[derive(Default)]
struct XSettings {
    window_scale: Option<f64>,
    xft_dpi: Option<f64>,
}

impl XSettings {
    fn device_scale(&self, resource_dpi: Option<f64>, text_scale: f64) -> Option<f64> {
        let from_dpi = |dpi: f64| dpi / (96.0 * text_scale);
        self.xft_dpi
            .map(from_dpi)
            .or(self.window_scale)
            .or_else(|| resource_dpi.map(from_dpi))
    }

    /// XSETTINGS v1 stores records on four-byte boundaries in the manager's
    /// byte order. Ignore strings/colors but consume their complete records.
    fn parse(data: &[u8]) -> Option<Self> {
        let little = match data.first()? {
            0 => true,
            1 => false,
            _ => return None,
        };
        let u32_at = |bytes: &[u8]| -> Option<u32> {
            let bytes = bytes.get(..4)?.try_into().ok()?;
            Some(if little {
                u32::from_le_bytes(bytes)
            } else {
                u32::from_be_bytes(bytes)
            })
        };
        let count = u32_at(data.get(8..)?)?;
        let mut records = data.get(12..)?;
        let mut result = Self::default();
        for _ in 0..count {
            let kind = *records.first()?;
            let len = records.get(2..4)?.try_into().ok()?;
            let len = usize::from(if little {
                u16::from_le_bytes(len)
            } else {
                u16::from_be_bytes(len)
            });
            let name = records.get(4..4 + len)?;
            records = records.get(8 + len.next_multiple_of(4)..)?;
            let size = match kind {
                0 => {
                    let value = u32_at(records)? as i32;
                    if value > 0 {
                        match name {
                            b"Gdk/WindowScalingFactor" => {
                                result.window_scale = Some(f64::from(value))
                            }
                            b"Xft/DPI" => result.xft_dpi = Some(f64::from(value) / 1024.0),
                            _ => {}
                        }
                    }
                    4
                }
                1 => 4usize.checked_add(
                    usize::try_from(u32_at(records)?)
                        .ok()?
                        .checked_next_multiple_of(4)?,
                )?,
                2 => 8,
                _ => return None,
            };
            records = records.get(size..)?;
        }
        Some(result)
    }
}

#[cfg(target_os = "linux")]
fn gnome_setting(key: &str) -> Option<f64> {
    let session = std::env::var("XDG_CURRENT_DESKTOP").ok()?;
    if !session.split(':').any(|s| s.eq_ignore_ascii_case("GNOME")) {
        return None;
    }
    let output = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", key])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    positive(
        std::str::from_utf8(&output.stdout)
            .ok()?
            .split_whitespace()
            .last(),
    )
}

#[cfg(target_os = "linux")]
pub(super) fn text_scale() -> f64 {
    static SCALE: std::sync::OnceLock<f64> = std::sync::OnceLock::new();
    *SCALE.get_or_init(|| gnome_setting("text-scaling-factor").unwrap_or(1.0))
}

#[cfg(target_os = "linux")]
pub(super) fn for_display(display: i64) -> f64 {
    use std::{env, sync::OnceLock};
    static SCALE: OnceLock<f64> = OnceLock::new();
    *SCALE.get_or_init(|| {
        scale(
            env::var("GDK_SCALE").ok().as_deref(),
            env::var("GDK_DPI_SCALE").ok().as_deref(),
            env::var("QT_SCALE_FACTOR").ok().as_deref(),
            || {
                x11_device_scale(display)
                    .or_else(|| gnome_setting("scaling-factor"))
                    .unwrap_or(1.0)
            },
        )
    })
}

#[cfg(target_os = "linux")]
fn x11_device_scale(display: i64) -> Option<f64> {
    use std::{
        ffi::{CStr, CString},
        ptr, slice,
    };
    use x11_dl::xlib;
    if display == 0 {
        return None;
    }
    let x = xlib::Xlib::open().ok()?;
    let display = display as *mut xlib::Display;
    // Borrow Godot's Xlib display on its main thread. The property bytes are
    // Xlib-owned and released after parsing. XGetDefault owns its string.
    unsafe {
        let setting = (x.XInternAtom)(display, c"_XSETTINGS_SETTINGS".as_ptr(), 1);
        let screen = (x.XDefaultScreen)(display);
        let name = CString::new(format!("_XSETTINGS_S{screen}")).ok()?;
        let selection = (x.XInternAtom)(display, name.as_ptr(), 1);
        let mut settings = XSettings::default();
        if selection != 0 && setting != 0 {
            // Prevent the settings manager from destroying its selection window
            // between these two reads. Only hold the grab for the two X calls.
            (x.XGrabServer)(display);
            let owner = (x.XGetSelectionOwner)(display, selection);
            let (mut actual, mut format, mut count, mut remaining) = (0, 0, 0, 0);
            let mut bytes = ptr::null_mut();
            let ok = owner != 0
                && (x.XGetWindowProperty)(
                    display,
                    owner,
                    setting,
                    0,
                    262144,
                    0,
                    setting,
                    &mut actual,
                    &mut format,
                    &mut count,
                    &mut remaining,
                    &mut bytes,
                ) == 0;
            (x.XUngrabServer)(display);
            (x.XFlush)(display);
            if !bytes.is_null() {
                if ok && actual == setting && format == 8 && remaining == 0 {
                    settings = XSettings::parse(slice::from_raw_parts(bytes, count as usize))
                        .unwrap_or_default();
                }
                (x.XFree)(bytes.cast());
            }
        }
        let raw = (x.XGetDefault)(display, c"Xft".as_ptr(), c"dpi".as_ptr());
        let resource = if raw.is_null() {
            None
        } else {
            positive(CStr::from_ptr(raw).to_str().ok())
        };
        settings.device_scale(resource, text_scale())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logical_dpi_and_toolkit_overrides() {
        let desktop = || XSettings::default().device_scale(Some(192.0), 1.0).unwrap();
        assert_eq!(scale(None, None, None, desktop), 2.0);
        assert_eq!(scale(Some("2"), None, None, desktop), 2.0);
        assert_eq!(scale(Some("2"), Some("0.75"), Some("2"), desktop), 1.5);
        assert_eq!(scale(None, Some("1.25"), None, desktop), 1.25);
        assert_eq!(scale(Some("nan"), Some("0"), Some("1.25"), desktop), 2.5);
    }

    #[test]
    fn xsettings_fixed_point_dpi_and_separate_gnome_text_zoom() {
        for little in [false, true] {
            let word = |n: u32| {
                if little {
                    n.to_le_bytes()
                } else {
                    n.to_be_bytes()
                }
            };
            let mut data = vec![0; 8];
            data[0] = u8::from(!little);
            data.extend(word(1));
            data.extend(if little { [0, 0, 7, 0] } else { [0, 0, 0, 7] });
            data.extend(b"Xft/DPI\0");
            data.extend(word(0));
            data.extend(word(240 * 1024));
            let mut settings = XSettings::parse(&data).unwrap();
            assert_eq!(settings.device_scale(Some(96.0), 1.25), Some(2.0));
            settings.window_scale = Some(1.5);
            assert_eq!(settings.device_scale(None, 1.25), Some(2.0));
            settings.xft_dpi = None;
            assert_eq!(settings.device_scale(None, 1.25), Some(1.5));
            assert!(XSettings::parse(&data[..data.len() - 1]).is_none());
        }
    }
}
