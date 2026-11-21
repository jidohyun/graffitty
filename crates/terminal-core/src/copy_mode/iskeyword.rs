//! Neovim's iskeyword grammar. Rules affect bytes 1..=255; higher Unicode
//! codepoints retain the editor's built-in word classes.
use std::sync::LazyLock;

pub const DEFAULT: &str = "@,48-57,_,192-255";

#[derive(Clone, Debug)]
pub struct IsKeyword {
    bytes: [bool; 256],
}

impl Default for IsKeyword {
    fn default() -> Self {
        Self::parse(DEFAULT).expect("valid default iskeyword")
    }
}

impl IsKeyword {
    /// Parse the actual option value (after string/shell escaping), not a :set
    /// command. Commas can be both separators and character endpoints.
    pub fn parse(source: &str) -> Result<Self, String> {
        let chars: Vec<char> = source.chars().collect();
        let mut at = 0;
        let mut result = Self {
            bytes: [false; 256],
        };
        let error = || format!("Invalid iskeyword: {source:?}");
        while at < chars.len() {
            let exclude = chars[at] == '^' && at + 1 < chars.len();
            if exclude {
                at += 1;
            }
            let first = number(&chars, &mut at).ok_or_else(error)?;
            let range = chars.get(at) == Some(&'-') && at + 1 < chars.len();
            let last = if range {
                at += 1;
                number(&chars, &mut at).ok_or_else(error)?
            } else {
                first
            };
            if first == 0 || last < first || last > 255 {
                return Err(error());
            }
            let alpha = first == u32::from('@') && !range;
            for value in if alpha { 1..=255 } else { first..=last } {
                let c = char::from_u32(value).unwrap();
                if !alpha || (c != 'ª' && c != 'º' && (c.is_lowercase() || c.is_uppercase())) {
                    result.bytes[value as usize] = !exclude;
                }
            }
            if at < chars.len() {
                if chars[at] != ',' {
                    return Err(error());
                }
                at += 1;
                while chars.get(at) == Some(&' ') {
                    at += 1;
                }
                if at == chars.len() {
                    return Err(error());
                }
            }
        }
        Ok(result)
    }

    pub fn contains(&self, c: char) -> bool {
        if (c as u32) < 256 {
            self.bytes[c as usize]
        } else {
            unicode_class(c) >= 2
        }
    }

    /// Motions distinguish scripts/emoji even though they are all keywords.
    pub(super) fn class(&self, c: char) -> u32 {
        if super::is_blank(c) {
            0
        } else if (c as u32) < 256 {
            if self.contains(c) {
                2
            } else {
                1
            }
        } else {
            unicode_class(c)
        }
    }
}

fn number(chars: &[char], at: &mut usize) -> Option<u32> {
    let c = *chars.get(*at)?;
    *at += 1;
    if !c.is_ascii_digit() {
        return Some(c as u32);
    }
    let mut n = c.to_digit(10)?;
    while let Some(d) = chars.get(*at).and_then(|c| c.to_digit(10)) {
        n = n.checked_mul(10)?.checked_add(d)?;
        *at += 1;
    }
    Some(n)
}

/// Fixed Unicode classes used by Vim/Neovim (utf_class_tab). The numeric script
/// IDs are only compared for equality. Emoji properties come from Unicode data.
pub(super) fn unicode_class(c: char) -> u32 {
    static EMOJI: LazyLock<fancy_regex::Regex> = LazyLock::new(|| {
        fancy_regex::Regex::new(r"^[\p{Extended_Pictographic}\p{Regional_Indicator}]$").unwrap()
    });
    let mut utf8 = [0; 4];
    if EMOJI.is_match(c.encode_utf8(&mut utf8)).unwrap_or(false) {
        return 3;
    }
    match c as u32 {
        0x1680 | 0x2000..=0x200b | 0x2028..=0x2029 | 0x202f | 0x205f | 0x3000 => 0,
        0x037e
        | 0x0387
        | 0x055a..=0x055f
        | 0x0589
        | 0x05be
        | 0x05c0
        | 0x05c3
        | 0x05f3..=0x05f4
        | 0x060c
        | 0x061b
        | 0x061f
        | 0x066a..=0x066d
        | 0x06d4
        | 0x0700..=0x070d
        | 0x0964..=0x0965
        | 0x0970
        | 0x0df4
        | 0x0e4f
        | 0x0e5a..=0x0e5b
        | 0x0f04..=0x0f12
        | 0x0f3a..=0x0f3d
        | 0x0f85
        | 0x104a..=0x104f
        | 0x10fb
        | 0x1361..=0x1368
        | 0x166d..=0x166e
        | 0x169b..=0x169c
        | 0x16eb..=0x16ed
        | 0x1735..=0x1736
        | 0x17d4..=0x17dc
        | 0x1800..=0x180a
        | 0x200c..=0x2027
        | 0x202a..=0x202e
        | 0x2030..=0x205e
        | 0x2060..=0x206f
        | 0x20a0..=0x27ff
        | 0x2900..=0x2998
        | 0x29d8..=0x29db
        | 0x29fc..=0x29fd
        | 0x2e00..=0x2e7f
        | 0x3001..=0x3020
        | 0x3030
        | 0x303d
        | 0xfd3e..=0xfd3f
        | 0xfe30..=0xfe6b
        | 0xff00..=0xff0f
        | 0xff1a..=0xff20
        | 0xff3b..=0xff40
        | 0xff5b..=0xff65
        | 0x1d000..=0x1d24f
        | 0x1d400..=0x1d7ff
        | 0x1f000..=0x1f2ff
        | 0x1f300..=0x1f9ff => 1,
        0x2070..=0x207f => 0x2070,
        0x2080..=0x2094 => 0x2080,
        0x2800..=0x28ff => 0x2800,
        0x3040..=0x309f => 0x3040,
        0x30a0..=0x30ff => 0x30a0,
        0x3300..=0x9fff
        | 0xf900..=0xfaff
        | 0x20000..=0x2a6df
        | 0x2a700..=0x2b73f
        | 0x2b740..=0x2b81f
        | 0x2f800..=0x2fa1f => 0x4e00,
        0xac00..=0xd7a3 => 0xac00,
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_neovim_for_every_byte_in_the_reference_options() {
        let reference: serde_json::Value =
            serde_json::from_str(include_str!("iskeyword_nvim.json")).unwrap();
        for case in reference["cases"].as_array().unwrap() {
            let source = case["source"].as_str().unwrap();
            let parsed = IsKeyword::parse(source);
            assert_eq!(
                parsed.is_ok(),
                case["valid"].as_bool().unwrap(),
                "{source:?}"
            );
            if let Ok(keyword) = parsed {
                let hex = case["members"].as_str().unwrap();
                for cp in 0..=255u32 {
                    let i = (cp / 8) as usize * 2;
                    let byte = u8::from_str_radix(&hex[i..i + 2], 16).unwrap();
                    assert_eq!(
                        keyword.contains(char::from_u32(cp).unwrap()),
                        byte & (1 << (cp % 8)) != 0,
                        "{source:?}, codepoint {cp}"
                    );
                }
            }
        }
    }

    #[test]
    fn parses_full_neovim_grammar_in_order() {
        for (source, included, excluded) in [
            (DEFAULT, "aAzZ09_é×µß", "-@,ª"),
            ("@", "aZéµß", "09_×ªº"),
            ("@,^a-z,x", "AZxé", "abc-_"),
            ("@,^@,_", "_", "aAé"),
            ("48-57,,,_", "09,_", "a-"),
            (" -~,^,,9", "az09_\t ", ",é"),
            ("_,-,128-140,#-43", "_-#$%&'()*+\u{80}\u{8c}", "az,\u{8d}"),
            ("a-z,A-Z,@-@", "aZ@", "_09é"),
            ("^a-z,#,^", "#^", "az,"),
            ("^", "^", "a,"),
            ("a,,", "a,", "b"),
            ("a, b", "ab", " "),
            ("a-c,^b,b", "abc", "d"),
            ("", "", "a0_é"),
        ] {
            let keyword = IsKeyword::parse(source).unwrap();
            for c in included.chars() {
                assert!(keyword.contains(c), "{source:?} must include {c:?}");
            }
            for c in excluded.chars() {
                assert!(!keyword.contains(c), "{source:?} must exclude {c:?}");
            }
        }
    }

    #[test]
    fn rejects_invalid_rules_without_partial_results() {
        for source in [
            "0",
            "256",
            "1-256",
            "z-a",
            "1-0",
            "a-",
            "@,",
            ",,",
            "a, ",
            "ab",
            "^,a",
            "가",
            "99999999999999999999999999",
            "a--z",
        ] {
            assert!(IsKeyword::parse(source).is_err(), "{source:?}");
        }
    }

    #[test]
    fn unicode_word_classes_are_independent_of_the_byte_option() {
        let keyword = IsKeyword::parse("").unwrap();
        for c in "한글漢字ひらがなカタカナω😀🇰".chars() {
            assert!(keyword.contains(c), "{c}");
        }
        for c in "—。\u{2003}".chars() {
            assert!(!keyword.contains(c), "{c}");
        }
        assert_ne!(keyword.class('한'), keyword.class('ω'));
        assert_ne!(keyword.class('한'), keyword.class('漢'));
        assert_eq!(keyword.class('😀'), 3);
        assert_eq!(keyword.class('🇰'), 3);
    }
}
