//! Bounded, passive OSC 9;4 observer. The VT still receives every original byte.
//! libghostty-vt 0.2 exposes scrollbar/title state but no progress payload.
#[derive(Default)]
pub struct Progress {
    mode: u8,
    bytes: Vec<u8>,
    overflow: bool,
    pub state: u8,
    /// -1 means no percentage was supplied, not zero percent.
    pub value: i16,
}

impl Progress {
    pub fn new() -> Self {
        Self {
            value: -1,
            ..Self::default()
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            if matches!(byte, 0x18 | 0x1a) {
                self.mode = 0; // CAN/SUB cancel any control string.
                self.bytes.clear();
                continue;
            }
            match self.mode {
                0 => {
                    if byte == 0x1b {
                        self.mode = 1;
                    }
                }
                1 => self.escape(byte),
                2 => match byte {
                    0x07 => {
                        self.finish();
                        self.mode = 0;
                    }
                    0x1b => self.mode = 3,
                    _ => {
                        if self.bytes.len() < 128 {
                            self.bytes.push(byte);
                        } else {
                            self.overflow = true;
                        }
                    }
                },
                3 => {
                    if byte == b'\\' {
                        self.finish();
                        self.mode = 0;
                    } else {
                        self.escape(byte);
                    }
                }
                // APC/DCS/PM/SOS payloads cannot inject OSC metadata.
                4 => {
                    if byte == 0x1b {
                        self.mode = 5;
                    }
                }
                5 => {
                    self.mode = if byte == b'\\' {
                        0
                    } else if byte == 0x1b {
                        5
                    } else {
                        4
                    }
                }
                _ => unreachable!(),
            }
        }
    }

    fn escape(&mut self, byte: u8) {
        self.mode = match byte {
            b']' => {
                self.bytes.clear();
                self.overflow = false;
                2
            }
            b'P' | b'_' | b'^' | b'X' => 4,
            0x1b => 1,
            _ => 0,
        };
    }

    fn finish(&mut self) {
        if self.overflow {
            return;
        }
        let Ok(text) = std::str::from_utf8(&self.bytes) else {
            return;
        };
        let Some(body) = text.strip_prefix("9;4;") else {
            return;
        };
        let mut fields = body.split(';');
        let Some(state) = fields.next() else {
            return;
        };
        if state.len() != 1 {
            return;
        }
        let Ok(state @ 0..=4) = state.parse::<u8>() else {
            return;
        };
        let value = match fields.next() {
            None => {
                if state == 1 {
                    0
                } else {
                    -1
                }
            }
            Some(value) => {
                if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                    return;
                }
                // Saturate while reading, including arbitrarily large values.
                value
                    .bytes()
                    .fold(0i16, |n, b| (n * 10 + i16::from(b - b'0')).min(100))
            }
        };
        if fields.next().is_some() {
            return;
        }
        self.state = state;
        self.value = if state == 0 || state == 3 { -1 } else { value };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_chunk_boundary_and_both_terminators() {
        for sequence in [b"\x1b]9;4;1;42\x07".as_slice(), b"\x1b]9;4;1;42\x1b\\"] {
            for split in 0..=sequence.len() {
                let mut p = Progress::new();
                p.feed(&sequence[..split]);
                p.feed(&sequence[split..]);
                assert_eq!((p.state, p.value), (1, 42));
            }
        }
    }
    #[test]
    fn states_optional_percent_and_invalid_input() {
        let mut p = Progress::new();
        for (seq, state, value) in [
            ("9;4;1", 1, 0),
            ("9;4;2", 2, -1),
            ("9;4;4;60", 4, 60),
            ("9;4;3;80", 3, -1),
            ("9;4;0", 0, -1),
            ("9;4;1;999999", 1, 100),
        ] {
            p.feed(format!("\x1b]{seq}\x07").as_bytes());
            assert_eq!((p.state, p.value), (state, value));
        }
        for seq in ["9;4;5;10", "9;4;1;-2", "9;4;1;hi", "9;4;1;2;3", "9;4;11;3"] {
            p.feed(format!("\x1b]{seq}\x07").as_bytes());
            assert_eq!((p.state, p.value), (1, 100));
        }
    }
    #[test]
    fn ignored_strings_cancellation_and_bounded_memory() {
        let mut p = Progress::new();
        p.feed(b"\x1bP\x1b]9;4;1;50\x07\x1b\\");
        p.feed(b"\x1b_\x1b]9;4;1;50\x07\x1b\\");
        p.feed(b"\x1b]9;4;1;50\x18\x07");
        assert_eq!(p.state, 0);
        p.feed(b"\x1b]9;4;1;");
        p.feed(&vec![b'9'; 10000]);
        p.feed(b"\x07");
        assert_eq!(p.state, 0);
        assert!(p.bytes.len() <= 128);
        p.feed(b"\x1b]9;4;4;20\x07");
        assert_eq!((p.state, p.value), (4, 20));
    }
}
