//! Streaming projection of terminal text. Graphics strings are consumed by
//! the owner and represented as resource/placement messages, never replayed
//! by a UI.
//!
//! Only an undecided control-string prefix is buffered, independently of
//! image size. String boundaries let the owner detect implicit image cursor
//! movement.
#[derive(Clone, Copy, Debug)]
pub enum Boundary {
    Begin,
    End { graphics: bool },
}

#[derive(Default)]
pub struct Filter {
    mode: u8,
    kind: u8,
    prefix: Vec<u8>,
    decided: bool,
    graphics: bool,
    escape: bool,
}

impl Filter {
    pub fn at_boundary(&self) -> bool {
        self.mode == 0
    }
    pub fn feed(&mut self, bytes: &[u8]) -> (Vec<u8>, Vec<(usize, Boundary)>) {
        let mut out = Vec::new();
        let mut boundaries = Vec::new();
        for (i, &b) in bytes.iter().enumerate() {
            match self.mode {
                0 if b == 27 => {
                    self.mode = 1;
                    self.prefix.push(b);
                }
                0 => out.push(b),
                1 => {
                    self.prefix.push(b);
                    if matches!(b, b'_' | b'P' | b']') {
                        self.mode = 2;
                        self.kind = b;
                        self.decided = false;
                        self.graphics = false;
                        self.escape = false;
                        boundaries.push((i + 1, Boundary::Begin));
                    } else {
                        out.append(&mut self.prefix);
                        self.mode = 0;
                    }
                }
                _ => {
                    let end = (self.escape && b == b'\\')
                        || (self.kind == b']' && b == 7)
                        || matches!(b, 0x18 | 0x1a);
                    if !self.decided {
                        self.prefix.push(b);
                        let body = &self.prefix[2..];
                        let decision = match self.kind {
                            b'_' => Some(body.starts_with(b"G")),
                            b'P' => body
                                .iter()
                                .position(|c| !(c.is_ascii_digit() || *c == b';'))
                                .map(|j| body[j] == b'q'),
                            b']' => {
                                let patterns: [&[u8]; 4] = [
                                    b"1337;File=",
                                    b"1337;FilePart=",
                                    b"1337;FileEnd",
                                    b"1337;MultipartFile=",
                                ];
                                if patterns.iter().any(|p| body.starts_with(p)) {
                                    Some(true)
                                } else if patterns.iter().any(|p| p.starts_with(body)) {
                                    None
                                } else {
                                    Some(false)
                                }
                            }
                            _ => Some(false),
                        };
                        if let Some(graphics) =
                            decision.or_else(|| (end || self.prefix.len() >= 64).then_some(false))
                        {
                            self.decided = true;
                            self.graphics = graphics;
                            if !graphics {
                                out.append(&mut self.prefix);
                            } else {
                                self.prefix.clear();
                            }
                        }
                    } else if !self.graphics {
                        out.push(b);
                    }
                    self.escape = b == 27;
                    if end {
                        boundaries.push((
                            i + 1,
                            Boundary::End {
                                graphics: self.graphics,
                            },
                        ));
                        self.mode = 0;
                        self.prefix.clear();
                    }
                }
            }
        }
        (out, boundaries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_fragment_boundaries_preserve_text_and_remove_only_images() {
        let source = b"a\x1b_Ga=T;AAAA\x1b\\b\x1bP0;1q123\x1b\\c\x1b]1337;File=xx:AAA\x07d\x1b]2;title\x07\x1bP$qm\x1b\\\x1b[31mZ";
        let expected = b"abcd\x1b]2;title\x07\x1bP$qm\x1b\\\x1b[31mZ";
        for split in 0..=source.len() {
            let mut filter = Filter::default();
            let (mut out, _) = filter.feed(&source[..split]);
            out.extend(filter.feed(&source[split..]).0);
            assert_eq!(out, expected, "split {split}");
        }
    }
    #[test]
    fn large_images_do_not_accumulate_in_the_projection() {
        let mut filter = Filter::default();
        filter.feed(b"\x1b_Gm=1;");
        for _ in 0..32 {
            assert!(filter.feed(&vec![b'A'; 65536]).0.is_empty());
        }
        assert!(filter.prefix.is_empty());
        assert_eq!(filter.feed(b"\x1b\\ok").0, b"ok");
    }
}
