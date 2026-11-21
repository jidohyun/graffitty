//! Shared color syntax for appearance and effect settings.
use anyhow::{Result, ensure};

pub fn rgb(value: &str) -> Result<Option<[u8; 3]>> {
    if value.is_empty() {
        return Ok(None);
    }
    ensure!(
        value.len() == 7
            && value.starts_with('#')
            && value[1..].bytes().all(|b| b.is_ascii_hexdigit()),
        "Colors must be #RRGGBB or blank"
    );
    let n = u32::from_str_radix(&value[1..], 16)?;
    Ok(Some([(n >> 16) as u8, (n >> 8) as u8, n as u8]))
}

pub fn rgba(value: &str) -> Result<[u8; 4]> {
    ensure!(
        (value.len() == 7 || value.len() == 9)
            && value.starts_with('#')
            && value[1..].bytes().all(|b| b.is_ascii_hexdigit()),
        "Color must be #RRGGBB or #RRGGBBAA"
    );
    let [r, g, b] = rgb(&value[..7])?.unwrap();
    Ok([
        r,
        g,
        b,
        if value.len() == 9 {
            u8::from_str_radix(&value[7..], 16)?
        } else {
            255
        },
    ])
}
