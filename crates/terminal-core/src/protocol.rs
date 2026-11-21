//! Bounded observer for application effects not exposed by libghostty-vt.
//! All bytes still go to the VT, in order. Opaque DCS/APC strings cannot inject OSCs.
use libghostty_vt::Terminal;
use libghostty_vt::screen::{RowSemanticPrompt, Screen};
use libghostty_vt::terminal::{Point, PointCoordinate, ScrollViewport};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    ClipboardRead(u8, bool), // selector, BEL terminator
    ClipboardWrite(u8, String), // selector, base64 payload
    Notification(String, String),
    Pointer(String),
    TitlePush,
    TitlePop,
    Capabilities(String),
    Sixel(Vec<u8>),
    ItermImage(String),
    KittyHeader(String),
    Erase { command: u8, count: u32 },
    Reset,
    Notify99(String),
    Clipboard5522(String),
}
#[derive(Default)]
pub struct Observer {
    mode: u8,
    bytes: Vec<u8>,
    overflow: bool,
}
impl Observer {
    pub fn feed(&mut self, data: &[u8]) -> Vec<(usize, Event)> {
        let mut events = Vec::new();
        self.feed_each(data, |end, event| {
            if events.len() < 64 {
                events.push((end, event));
            }
        });
        events
    }

    /// Deliver ordered events without an intermediate event list. Storage stays
    /// bounded by the existing per-packet limits; stream consumers must use this
    /// method when a coalesced transport packet can contain more than 64 effects.
    pub fn feed_each(&mut self, data: &[u8], mut emit: impl FnMut(usize, Event)) {
        for (i, &b) in data.iter().enumerate() {
            if matches!(b, 0x18 | 0x1a) {
                self.mode = 0;
                self.bytes.clear();
                continue;
            }
            let mut event = None;
            match self.mode {
                0 => {
                    if b == 0x1b {
                        self.mode = 1;
                    }
                }
                1 => {
                    if b == b'c' {
                        event = Some(Event::Reset);
                    }
                    self.escape(b);
                }
                2 => match b {
                    7 => {
                        event = self.osc(true);
                        self.mode = 0;
                    }
                    0x1b => self.mode = 3,
                    _ => self.push(b),
                },
                3 => {
                    if b == b'\\' {
                        event = self.osc(false);
                        self.mode = 0;
                    } else {
                        self.escape(b);
                    }
                }
                7 => {
                    if b == 0x1b {
                        self.mode = 8;
                    } else {
                        self.push(b);
                    }
                }
                8 => {
                    if b == b'\\' {
                        if !self.overflow {
                            if let Ok(s) = std::str::from_utf8(&self.bytes) {
                                if let Some(query) = s.strip_prefix("+q") {
                                    event = Some(Event::Capabilities(query.to_owned()));
                                } else if s.split_once('q').is_some_and(|(h, _)| {
                                    h.bytes().all(|b| b.is_ascii_digit() || b == b';')
                                }) {
                                    event = Some(Event::Sixel(self.bytes.clone()));
                                }
                            }
                        }
                        self.mode = 0;
                    } else {
                        self.push(0x1b);
                        self.push(b);
                        self.mode = 7;
                    }
                }
                4 => {
                    if b == 0x1b {
                        self.mode = 5;
                    }
                }
                9 => {
                    if b == 0x1b {
                        self.mode = 10;
                    } else if b == b';' {
                        if !self.overflow && self.bytes.starts_with(b"G") {
                            event = Some(Event::KittyHeader(
                                String::from_utf8_lossy(&self.bytes[1..]).into_owned(),
                            ));
                        }
                        self.mode = 4;
                    } else {
                        self.push(b);
                    }
                }
                10 => {
                    if b == b'\\' {
                        if !self.overflow && self.bytes.starts_with(b"G") {
                            event = Some(Event::KittyHeader(
                                String::from_utf8_lossy(&self.bytes[1..]).into_owned(),
                            ));
                        }
                        self.mode = 0;
                    } else {
                        self.mode = 4;
                    }
                }
                5 => {
                    self.mode = if b == b'\\' {
                        0
                    } else if b == 0x1b {
                        5
                    } else {
                        4
                    }
                }
                6 => {
                    if (0x40..=0x7e).contains(&b) {
                        if !self.overflow
                            && matches!(b, b'J' | b'K' | b'X')
                            && self.bytes.iter().all(u8::is_ascii_digit)
                        {
                            let count = if self.bytes.is_empty() {
                                Some(0)
                            } else {
                                std::str::from_utf8(&self.bytes)
                                    .ok()
                                    .and_then(|s| s.parse().ok())
                            };
                            event = count.map(|count| Event::Erase { command: b, count });
                        }
                        if !self.overflow && b == b't' {
                            event = match self.bytes.as_slice() {
                                b"22;0" | b"22;2" => Some(Event::TitlePush),
                                b"23;0" | b"23;2" => Some(Event::TitlePop),
                                _ => None,
                            };
                        }
                        self.mode = 0;
                    } else if b == 0x1b {
                        self.mode = 1;
                    } else {
                        self.push(b);
                    }
                }
                _ => unreachable!(),
            }
            if let Some(event) = event {
                emit(i + 1, event);
            }
        }
    }
    fn escape(&mut self, b: u8) {
        self.bytes.clear();
        self.overflow = false;
        self.mode = match b {
            b']' => 2,
            b'[' => 6,
            b'P' => 7,
            b'_' => 9,
            b'^' | b'X' => 4,
            0x1b => 1,
            _ => 0,
        };
    }
    fn push(&mut self, b: u8) {
        let image = self.mode == 7
            || self.bytes.starts_with(b"1337;File=")
            || self.bytes.starts_with(b"1337;FilePart=");
        let limit = if image { 32 * 1024 * 1024 } else if self.bytes.starts_with(b"52;") { 1400000 } else { 8192 };
        if self.bytes.len() < limit {
            self.bytes.push(b);
        } else {
            self.overflow = true;
        }
    }
    fn osc(&self, bel: bool) -> Option<Event> {
        if self.overflow {
            return None;
        }
        let s = std::str::from_utf8(&self.bytes).ok()?;
        if let Some(body) = s
            .strip_prefix("1337;")
            .filter(|s| s.starts_with("File") || s.starts_with("MultipartFile="))
        {
            return Some(Event::ItermImage(body.into()));
        }
        if let Some(body) = s.strip_prefix("99;") {
            return Some(Event::Notify99(body.into()));
        }
        if let Some(body) = s.strip_prefix("5522;") {
            return Some(Event::Clipboard5522(body.into()));
        }
        if let Some(body) = s.strip_prefix("52;") {
            let (selector, payload) = body.split_once(';')?;
            let c = if selector.is_empty() {
                b'c'
            } else {
                selector.bytes().find(|c| matches!(c, b'c' | b'p' | b's'))?
            };
            return Some(if payload == "?" { Event::ClipboardRead(c, bel) } else { Event::ClipboardWrite(c, payload.into()) });
        }
        if let Some(body) = s.strip_prefix("777;notify;") {
            let (title, body) = body.split_once(';').unwrap_or((body, ""));
            return Some(Event::Notification(clean(title), clean(body)));
        }
        if let Some(body) = s.strip_prefix("9;") {
            if !body.starts_with("4;") {
                return Some(Event::Notification("Terminal".into(), clean(body)));
            }
        }
        if let Some(shape) = s.strip_prefix("22;") {
            return Some(Event::Pointer(shape.into()));
        }
        None
    }
}
fn clean(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(2048).collect()
}

pub fn prompt_rows(vt: &Terminal<'_, '_>) -> Vec<usize> {
    if vt.active_screen().ok() == Some(Screen::Alternate) {
        return vec![];
    }
    (0..vt.total_rows().unwrap_or(0))
        .filter(|&y| {
            vt.grid_ref(Point::Screen(PointCoordinate { x: 0, y: y as u32 }))
                .ok()
                .and_then(|r| r.row().ok())
                .is_some_and(|r| {
                    r.semantic_prompt().ok() == Some(RowSemanticPrompt::Prompt)
                        && !r.is_wrap_continuation().unwrap_or(false)
                })
        })
        .collect()
}
pub fn jump_prompt(vt: &mut Terminal<'_, '_>, direction: i64) -> bool {
    if vt.active_screen().ok() == Some(Screen::Alternate) || direction == 0 {
        return false;
    }
    let Ok(scroll) = vt.scrollbar() else {
        return false;
    };
    let top = scroll.offset as usize;
    let rows = prompt_rows(vt);
    let target = if direction < 0 {
        rows.into_iter().rev().find(|&r| r < top)
    } else {
        rows.into_iter().find(|&r| r > top)
    };
    if let Some(row) = target {
        vt.scroll_viewport(ScrollViewport::Row(row));
    } else if direction > 0 {
        vt.scroll_viewport(ScrollViewport::Bottom);
    }
    true
}

pub fn hyperlink(vt: &Terminal<'_, '_>, x: u16, y: u32) -> Option<String> {
    let cell = vt
        .grid_ref(Point::Viewport(PointCoordinate { x, y }))
        .ok()?;
    let mut data = vec![0; 512];
    let len = match cell.hyperlink_uri(&mut data) {
        Err(libghostty_vt::Error::OutOfSpace { required }) if required <= 65536 => {
            data.resize(required, 0);
            cell.hyperlink_uri(&mut data).ok()?
        }
        other => other.ok()?,
    };
    let uri = std::str::from_utf8(&data[..len]).ok()?.to_owned();
    (!uri.is_empty()).then_some(uri)
}
pub fn openable_link(uri: &str) -> bool {
    !uri.chars().any(char::is_control)
        && uri.split_once(':').is_some_and(|(scheme, _)| {
            matches!(
                scheme.to_ascii_lowercase().as_str(),
                "http" | "https" | "mailto" | "file" | "ftp" | "ssh"
            )
        })
}

pub fn web_link(uri: &str) -> bool {
    openable_link(uri)
        && uri.split_once("://").is_some_and(|(scheme, _)| {
            scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_writes_survive_fragmentation_and_remain_bounded() {
        let payload = "YWFh".repeat(8192);
        let bytes = format!("\x1b]52;c;{payload}\x1b\\\x1b]52;c;?\x07");
        for chunk in [1, 4095, 4096, 8192, 16384] {
            let mut observer = Observer::default();
            let mut events = vec![];
            for part in bytes.as_bytes().chunks(chunk) {
                observer.feed_each(part, |_, event| events.push(event));
            }
            assert_eq!(events, vec![Event::ClipboardWrite(b'c', payload.clone()), Event::ClipboardRead(b'c', true)]);
        }
        let mut observer = Observer::default();
        observer.feed(b"\x1b]52;c;");
        observer.feed(&vec![b'A'; 1_400_001]);
        assert!(observer.feed(b"\x1b\\").is_empty());
        assert_eq!(observer.feed(b"\x1b]52;c;?\x07")[0].1, Event::ClipboardRead(b'c', true));
    }
    #[test]
    fn fragmented_effects_and_opaque_strings() {
        let data = b"\x1b]52;c;?\x1b\\\x1b]777;notify;Build;Done\x07\x1b[22;2t\x1b[23;0t";
        for split in 0..=data.len() {
            let mut p = Observer::default();
            let mut events = p.feed(&data[..split]);
            events.extend(p.feed(&data[split..]));
            assert_eq!(
                events.into_iter().map(|e| e.1).collect::<Vec<_>>(),
                [
                    Event::ClipboardRead(b'c', false),
                    Event::Notification("Build".into(), "Done".into()),
                    Event::TitlePush,
                    Event::TitlePop
                ]
            );
        }
        let mut p = Observer::default();
        assert!(
            p.feed(b"\x1bP\x1b]52;c;?\x07\x1b\\\x1b_\x1b]9;bad\x07\x1b\\\x1b]52;c;?\x18\x07")
                .is_empty()
        );
        p.feed(b"\x1b]9;");
        p.feed(&vec![b'a'; 10000]);
        assert!(p.feed(b"\x07").is_empty());
        assert_eq!(
            p.feed(b"\x1b]22;pointer\x07")[0].1,
            Event::Pointer("pointer".into())
        );
    }
    #[test]
    fn prompt_and_hidden_hyperlink() {
        let mut vt = crate::new_vt(40, 3, 100).unwrap();
        vt.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07echo hi\r\n\x1b]133;C\x07hi\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07\r\n\x1b]8;;https://example.test\x1b\\click here\x1b]8;;\x1b\\");
        assert_eq!(prompt_rows(&vt), [0, 2]);
        assert_eq!(
            hyperlink(&vt, 0, 2).as_deref(),
            Some("https://example.test")
        );
        assert!(jump_prompt(&mut vt, -1));
        assert_eq!(vt.scrollbar().unwrap().offset, 0);
        assert!(jump_prompt(&mut vt, 1));
        assert_eq!(vt.scrollbar().unwrap().offset, 1);
        assert!(!openable_link("javascript:alert(1)"));
        assert!(openable_link("https://example.test"));
    }
}

/// Return only capabilities implemented by this terminal; unknown requests fail.
pub fn capabilities(query: &str) -> String {
    let mut response = String::new();
    for encoded in query.split(';').take(64) {
        let Some(name) = unhex(encoded) else {
            continue;
        };
        let value = match name.as_str() {
            "TN" | "name" => Some("xterm-ghostty"),
            "Co" | "colors" => Some("256"),
            "RGB" | "Tc" | "Su" => Some(""),
            "am" | "bce" | "km" | "mir" | "msgr" | "xenl" => Some(""),
            "AX" | "XT" => Some(""),
            "Ms" => Some("\x1b]52;%p1%s;%p2%s\x07"),
            "Ss" => Some("\x1b[%p1%d q"),
            "Se" => Some("\x1b[2 q"),
            "Smulx" => Some("\x1b[4:%p1%dm"),
            "setrgbf" => Some("\x1b[38;2;%p1%d;%p2%d;%p3%dm"),
            "setrgbb" => Some("\x1b[48;2;%p1%d;%p2%d;%p3%dm"),
            "smcup" | "ti" => Some("\x1b[?1049h"),
            "rmcup" | "te" => Some("\x1b[?1049l"),
            "clear" | "cl" => Some("\x1b[H\x1b[2J"),
            "cup" | "cm" => Some("\x1b[%i%p1%d;%p2%dH"),
            "sgr0" | "me" => Some("\x1b(B\x1b[m"),
            "civis" | "vi" => Some("\x1b[?25l"),
            "cnorm" | "ve" => Some("\x1b[?25h"),
            "kcuu1" | "ku" => Some("\x1bOA"),
            "kcud1" | "kd" => Some("\x1bOB"),
            "kcuf1" | "kr" => Some("\x1bOC"),
            "kcub1" | "kl" => Some("\x1bOD"),
            "kbs" | "kb" => Some("\x7f"),
            _ => None,
        };
        response.push_str(&format!(
            "\x1bP{}+r{}",
            if value.is_some() { 1 } else { 0 },
            encoded
        ));
        if let Some(value) = value.filter(|v| !v.is_empty()) {
            response.push('=');
            response.push_str(&hex(value));
        }
        response.push_str("\x1b\\");
    }
    response
}
fn unhex(s: &str) -> Option<String> {
    if s.len() % 2 != 0 || !s.is_ascii() {
        return None;
    }
    String::from_utf8(
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16))
            .collect::<Result<Vec<_>, _>>()
            .ok()?,
    )
    .ok()
}
fn hex(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}

#[derive(Default)]
pub struct Pointers {
    stacks: [Vec<String>; 2],
}
impl Pointers {
    pub fn current(&self, alternate: bool) -> &str {
        self.stacks[alternate as usize]
            .last()
            .map(String::as_str)
            .unwrap_or("")
    }
    pub fn apply(&mut self, alternate: bool, command: &str) -> Option<String> {
        let stack = &mut self.stacks[alternate as usize];
        if let Some(query) = command.strip_prefix('?') {
            let values: Vec<_> = query
                .split(',')
                .take(64)
                .map(|name| match name {
                    "__current__" => stack.last().map(String::as_str).unwrap_or("0"),
                    "__default__" | "__grabbed__" => "text",
                    _ => {
                        if pointer_supported(name) {
                            "1"
                        } else {
                            "0"
                        }
                    }
                })
                .collect();
            return Some(format!("\x1b]22;{}\x1b\\", values.join(",")));
        }
        if command.starts_with('<') {
            stack.pop();
        } else if let Some(names) = command.strip_prefix('>') {
            for name in names.split(',').filter(|n| pointer_supported(n)) {
                if stack.len() >= 16 {
                    stack.remove(0);
                }
                stack.push(name.into());
            }
        } else {
            let name = command.strip_prefix('=').unwrap_or(command);
            if name.is_empty() {
                stack.clear();
            } else if pointer_supported(name) {
                if let Some(top) = stack.last_mut() {
                    *top = name.into();
                } else {
                    stack.push(name.into());
                }
            }
        }
        None
    }
}
fn pointer_supported(name: &str) -> bool {
    matches!(
        name,
        "default"
            | "text"
            | "pointer"
            | "crosshair"
            | "wait"
            | "progress"
            | "not-allowed"
            | "no-drop"
            | "move"
            | "all-scroll"
            | "help"
            | "ew-resize"
            | "col-resize"
            | "ns-resize"
            | "row-resize"
            | "nesw-resize"
            | "nwse-resize"
    )
}

#[cfg(test)]
mod extended_tests {
    use super::*;
    #[test]
    fn pointer_stacks_and_capability_queries() {
        let mut p = Pointers::default();
        p.apply(false, "pointer");
        p.apply(false, ">wait,crosshair");
        assert_eq!(p.current(false), "crosshair");
        p.apply(false, "<");
        assert_eq!(p.current(false), "wait");
        assert_eq!(p.current(true), "");
        p.apply(true, "text");
        assert_eq!(p.current(false), "wait");
        assert_eq!(
            p.apply(false, "?__current__,__default__,pointer,bogus")
                .unwrap(),
            "\x1b]22;wait,text,1,0\x1b\\"
        );
        assert_eq!(
            capabilities("544e;436f;626f677573"),
            "\x1bP1+r544e=787465726d2d67686f73747479\x1b\\\x1bP1+r436f=323536\x1b\\\x1bP0+r626f677573\x1b\\"
        );
        let bytes = b"\x1bP+q544e\x1b\\";
        for split in 0..bytes.len() {
            let mut observer = Observer::default();
            let mut events = observer.feed(&bytes[..split]);
            events.extend(observer.feed(&bytes[split..]));
            assert_eq!(
                events.into_iter().map(|e| e.1).collect::<Vec<_>>(),
                [Event::Capabilities("544e".into())]
            );
        }
    }
}

pub fn custom_hyperlink(
    vt: &Terminal<'_, '_>,
    x: u16,
    y: u32,
    patterns: &[std::sync::Arc<fancy_regex::Regex>],
) -> Option<String> {
    hyperlink_match(vt, x, y, patterns).map(|link| link.uri)
}

/// The URI and its visible hit/decoration cells, including wide glyph tails.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HyperlinkMatch {
    pub uri: String,
    pub cells: std::collections::HashSet<(u16, u32)>,
}

pub fn hyperlink_match(
    vt: &Terminal<'_, '_>,
    x: u16,
    y: u32,
    patterns: &[std::sync::Arc<fancy_regex::Regex>],
) -> Option<HyperlinkMatch> {
    let cols = vt.cols().ok()?;
    let rows = u32::from(vt.rows().ok()?);
    if x >= cols || y >= rows {
        return None;
    }
    if let Some(uri) = hyperlink(vt, x, y) {
        if !openable_link(&uri) {
            return None;
        }
        let mut cells = std::collections::HashSet::new();
        let adjacent = |(col, row): (u16, u32), next: bool| -> Option<(u16, u32)> {
            if next && col + 1 < cols {
                return Some((col + 1, row));
            }
            if !next && col > 0 {
                return Some((col - 1, row));
            }
            let before = if next { row } else { row.checked_sub(1)? };
            if before + 1 >= rows
                || !vt
                    .grid_ref(Point::Viewport(PointCoordinate { x: 0, y: before }))
                    .ok()?
                    .row()
                    .ok()?
                    .is_wrapped()
                    .ok()?
            {
                return None;
            }
            Some(if next {
                (0, row + 1)
            } else {
                (cols - 1, row - 1)
            })
        };
        for next in [false, true] {
            let mut at = (x, y);
            cells.insert(at);
            while let Some(cell) = adjacent(at, next) {
                if hyperlink(vt, cell.0, cell.1).as_deref() != Some(uri.as_str()) {
                    break;
                }
                cells.insert(cell);
                at = cell;
            }
        }
        return Some(HyperlinkMatch { uri, cells });
    }
    if patterns.is_empty() {
        return None;
    }
    let top = vt.scrollbar().ok()?.offset as u32;
    let target_y = top + y;
    let cols = vt.cols().ok()?;
    let mut first = target_y;
    let point = |x, y| Point::Screen(PointCoordinate { x, y });
    while first > 0
        && target_y - first < 512
        && vt
            .grid_ref(point(0, first))
            .ok()?
            .row()
            .ok()?
            .is_wrap_continuation()
            .ok()?
    {
        first -= 1;
    }
    let mut row = first;
    let mut text = String::new();
    let mut target = None;
    let mut positions = Vec::new();
    let mut chars = vec!['\0'; 8];
    loop {
        for col in 0..cols {
            let cell = vt.grid_ref(point(col, row)).ok()?;
            use libghostty_vt::screen::CellWide;
            let wide = cell.cell().ok()?.wide().ok()?;
            if matches!(wide, CellWide::SpacerHead | CellWide::SpacerTail) {
                continue;
            }
            if row == target_y && (col == x || (wide == CellWide::Wide && col + 1 == x)) {
                target = Some(text.len());
            }
            if row >= top && row - top < rows {
                positions.push((text.len(), (col, row - top)));
                if wide == CellWide::Wide && col + 1 < cols {
                    positions.push((text.len(), (col + 1, row - top)));
                }
            }
            let n = match cell.graphemes(&mut chars) {
                Err(libghostty_vt::Error::OutOfSpace { required }) => {
                    chars.resize(required, '\0');
                    cell.graphemes(&mut chars).ok()?
                }
                other => other.ok()?,
            };
            if n == 0 {
                text.push(' ');
            } else {
                text.extend(&chars[..n]);
            }
        }
        if text.len() >= 65536
            || !vt
                .grid_ref(point(0, row))
                .ok()?
                .row()
                .ok()?
                .is_wrapped()
                .ok()?
            || row + 1 >= vt.total_rows().ok()? as u32
        {
            break;
        }
        row += 1;
    }
    let at = target?;
    for pattern in patterns {
        for captures in pattern.captures_iter(&text).flatten() {
            let whole = captures.get(0)?;
            if whole.start() <= at && at < whole.end() {
                if let Some(found) = (0..captures.len()).rev().find_map(|i| captures.get(i)) {
                    let uri = found.as_str();
                    if openable_link(uri) {
                        let cells = positions
                            .iter()
                            .filter(|(byte, _)| whole.start() <= *byte && *byte < whole.end())
                            .map(|(_, cell)| *cell)
                            .collect();
                        return Some(HyperlinkMatch {
                            uri: uri.to_owned(),
                            cells,
                        });
                    }
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod hyperlink_tests {
    use super::*;

    fn terminal(cols: u16, rows: u16) -> Terminal<'static, 'static> {
        crate::new_vt(cols, rows, 100).unwrap()
    }

    #[test]
    fn osc8_labels_include_wide_cells_and_wrapped_rows_only() {
        let mut vt = terminal(8, 4);
        vt.vt_write("\x1b]8;;file:///tmp/demo\x1b\\한글abcdef\x1b]8;;\x1b\\ outside\r\n\x1b]8;;file:///tmp/demo\x1b\\other\x1b]8;;\x1b\\".as_bytes());
        let link = hyperlink_match(&vt, 0, 0, &[]).unwrap();
        assert_eq!(link.uri, "file:///tmp/demo");
        assert_eq!(link.cells.len(), 10);
        assert!(
            link.cells.contains(&(1, 0)),
            "wide glyph tail is underlined"
        );
        assert!(link.cells.contains(&(1, 1)), "soft wrap remains one target");
        assert!(!link.cells.contains(&(2, 1)), "unlinked space is excluded");
        assert!(
            !link.cells.contains(&(0, 3)),
            "separate hard line is excluded"
        );
        assert_eq!(hyperlink_match(&vt, 1, 0, &[]), Some(link));
    }

    #[test]
    fn regex_links_track_cell_positions_and_scroll() {
        let mut vt = terminal(20, 3);
        let patterns = [std::sync::Arc::new(
            fancy_regex::Regex::new(r"https://[^\s]+").unwrap(),
        )];
        vt.vt_write("한 é https://example.test/path END\r\nnext\r\nlast".as_bytes());
        vt.scroll_viewport(ScrollViewport::Top);
        let link = hyperlink_match(&vt, 5, 0, &patterns).unwrap();
        assert_eq!(link.uri, "https://example.test/path");
        assert_eq!(link.cells.len(), link.uri.len());
        assert!(!link.cells.contains(&(4, 0)));
        assert!(link.cells.contains(&(0, 1)));
        vt.scroll_viewport(ScrollViewport::Bottom);
        assert_eq!(hyperlink_match(&vt, 0, 0, &patterns).unwrap().uri, link.uri);
        assert!(hyperlink_match(&vt, 20, 0, &patterns).is_none());
        assert!(hyperlink_match(&vt, 0, 3, &patterns).is_none());
    }

    #[test]
    fn osc8_does_not_extend_to_icons_or_unsupported_schemes() {
        let mut vt = terminal(40, 3);
        vt.vt_write("\u{e68b} \x1b]8;;file:///tmp/Cargo.toml\x1b\\Cargo.toml\x1b]8;;\x1b\\\r\n\x1b]8;;javascript:alert(1)\x1b\\bad\x1b]8;;\x1b\\".as_bytes());
        assert!(hyperlink_match(&vt, 0, 0, &[]).is_none());
        assert_eq!(
            hyperlink_match(&vt, 2, 0, &[]).unwrap().uri,
            "file:///tmp/Cargo.toml"
        );
        assert!(hyperlink_match(&vt, 0, 1, &[]).is_none());
    }

    #[test]
    fn osc8_targets_survive_frontend_resynchronization() {
        let mut owner = terminal(40, 3);
        owner.vt_write(b"\x1b]8;;file:///tmp/Cargo.toml\x1b\\Cargo.toml\x1b]8;;\x1b\\\r\n");
        let mut client = terminal(40, 3);
        client.vt_write(&crate::checkpoint::capture_frontend(&mut owner).unwrap());
        assert_eq!(
            custom_hyperlink(&client, 0, 0, &[]).as_deref(),
            Some("file:///tmp/Cargo.toml")
        );
    }
}

/// Answer before subsequent DA1 bytes enter the VT; clients rely on this ordering.
pub fn notification_query(packet: &str) -> Option<String> {
    let (meta, _) = packet.split_once(';')?;
    let mut kind = "title";
    let mut id = "0";
    for field in meta.split(':') {
        if let Some(value) = field.strip_prefix("p=") {
            kind = value;
        }
        if let Some(value) = field.strip_prefix("i=") {
            id = value;
        }
    }
    if kind != "?" {
        return None;
    }
    if id.is_empty() {
        id = "0";
    }
    if id.len() > 256
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_+.-".contains(&b))
    {
        return None;
    }
    let urgency = if cfg!(target_os = "macos") {
        ""
    } else {
        ":u=0,1,2"
    };
    Some(format!(
        "\x1b]99;i={id}:p=?;a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,icon,buttons,alive,close,?:s=system,silent,error,warn,warning,info,question:w=1{urgency}\x1b\\"
    ))
}

#[cfg(test)]
mod notification_query_tests {
    use super::*;
    #[test]
    fn query_replies_are_scoped_and_safe() {
        assert!(
            notification_query("i=client:p=?;")
                .unwrap()
                .starts_with("\x1b]99;i=client:p=?;a=focus,report")
        );
        assert!(
            notification_query("p=?;")
                .unwrap()
                .starts_with("\x1b]99;i=0:p=?;")
        );
        assert!(notification_query("i=bad id:p=?;").is_none());
        assert!(notification_query("i=normal;Hello").is_none());
    }
}
