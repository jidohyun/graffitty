//! Windows MIME adapter. Native text/PNG formats accompany exact MIME payloads.
//! Callers enforce clipboard permissions before entering this module.
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::Arc;

type Handle = *mut c_void;
const LIMIT: usize = 64 * 1024 * 1024;
const MIME_PREFIX: &str = "Graffitty MIME ";
const UNICODE_TEXT: u32 = 13;

#[link(name = "user32")]
unsafe extern "system" {
    fn OpenClipboard(window: Handle) -> i32;
    fn CloseClipboard() -> i32;
    fn EmptyClipboard() -> i32;
    fn SetClipboardData(format: u32, memory: Handle) -> Handle;
    fn GetClipboardData(format: u32) -> Handle;
    fn EnumClipboardFormats(format: u32) -> u32;
    fn RegisterClipboardFormatW(name: *const u16) -> u32;
    fn GetClipboardFormatNameW(format: u32, name: *mut u16, count: i32) -> i32;
    fn CreateWindowExW(
        ex: u32,
        class: *const u16,
        name: *const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: Handle,
        menu: Handle,
        instance: Handle,
        param: Handle,
    ) -> Handle;
    fn DestroyWindow(window: Handle) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GlobalAlloc(flags: u32, size: usize) -> Handle;
    fn GlobalFree(memory: Handle) -> Handle;
    fn GlobalLock(memory: Handle) -> Handle;
    fn GlobalUnlock(memory: Handle) -> i32;
    fn GlobalSize(memory: Handle) -> usize;
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

fn register(name: &str) -> u32 {
    unsafe { RegisterClipboardFormatW(wide(name).as_ptr()) }
}

struct Window(Handle);
impl Window {
    fn new() -> Option<Self> {
        // OpenClipboard(NULL) followed by EmptyClipboard cannot set ownership.
        // A message-only window supplies an owner without presenting any UI.
        let window = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                wide("").as_ptr(),
                0,
                0,
                0,
                0,
                0,
                -3isize as Handle,
                null_mut(),
                null_mut(),
                null_mut(),
            )
        };
        (!window.is_null()).then_some(Self(window))
    }
}
impl Drop for Window {
    fn drop(&mut self) {
        unsafe {
            DestroyWindow(self.0);
        }
    }
}

struct Open;
impl Open {
    fn new(owner: Handle) -> Option<Self> {
        for attempt in 0..5 {
            if unsafe { OpenClipboard(owner) } != 0 {
                return Some(Self);
            }
            if attempt < 4 {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }
        None
    }
}
impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            CloseClipboard();
        }
    }
}

struct Memory(Handle);
impl Memory {
    fn new(bytes: &[u8]) -> Option<Self> {
        let memory = Self(unsafe { GlobalAlloc(2, bytes.len().max(1)) }); // GMEM_MOVEABLE
        if memory.0.is_null() {
            return None;
        }
        let target = unsafe { GlobalLock(memory.0) };
        if target.is_null() {
            return None;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), target.cast::<u8>(), bytes.len());
            GlobalUnlock(memory.0);
        }
        Some(memory)
    }
}
impl Drop for Memory {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                GlobalFree(self.0);
            }
        }
    }
}

fn valid_mime(mime: &str) -> bool {
    mime.len() <= 200 && mime.contains('/') && mime.bytes().all(|b| b.is_ascii_graphic())
}

/// Preallocate and validate before EmptyClipboard; ownership moves only on success.
pub fn write(data: &BTreeMap<String, Arc<Vec<u8>>>) -> bool {
    if data.len() > 64 || data.values().map(|v| v.len()).sum::<usize>() > LIMIT {
        return false;
    }
    let mut formats: Vec<(u32, Memory)> = Vec::new();
    for (mime, bytes) in data {
        if !valid_mime(mime) {
            return false;
        }
        // HGLOBAL may be rounded up. A size prefix in our explicitly named
        // format preserves binary trailing NULs; standard companion formats
        // remain native Windows text/PNG, with no private framing in them.
        let mut framed = (bytes.len() as u64).to_le_bytes().to_vec();
        framed.extend_from_slice(bytes);
        let Some(memory) = Memory::new(&framed) else {
            return false;
        };
        let format = register(&format!("{MIME_PREFIX}{mime}"));
        if format == 0 {
            return false;
        }
        formats.push((format, memory));
        let native = if mime == "text/plain" {
            let Ok(text) = std::str::from_utf8(bytes) else {
                return false;
            };
            Some((
                UNICODE_TEXT,
                wide(text)
                    .into_iter()
                    .flat_map(u16::to_le_bytes)
                    .collect::<Vec<_>>(),
            ))
        } else if mime == "image/png" {
            Some((register("PNG"), bytes.as_ref().clone()))
        } else {
            None
        };
        if let Some((format, bytes)) = native {
            if format == 0 {
                return false;
            }
            let Some(memory) = Memory::new(&bytes) else {
                return false;
            };
            formats.push((format, memory));
        }
    }
    let Some(owner) = Window::new() else {
        return false;
    };
    let Some(_open) = Open::new(owner.0) else {
        return false;
    };
    if unsafe { EmptyClipboard() } == 0 {
        return false;
    }
    for (format, mut memory) in formats {
        if unsafe { SetClipboardData(format, memory.0) }.is_null() {
            return false;
        }
        memory.0 = null_mut(); // The OS now owns this allocation.
    }
    true
}

fn bytes(format: u32) -> Option<Vec<u8>> {
    if format == 0 {
        return None;
    }
    let memory = unsafe { GetClipboardData(format) };
    if memory.is_null() {
        return None;
    }
    let size = unsafe { GlobalSize(memory) };
    if size == 0 || size > LIMIT * 2 + 16 {
        return None;
    }
    let pointer = unsafe { GlobalLock(memory) };
    if pointer.is_null() {
        return None;
    }
    let result = unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), size).to_vec() };
    unsafe {
        GlobalUnlock(memory);
    }
    Some(result)
}

pub fn get(mime: &str) -> Option<Vec<u8>> {
    let _open = Open::new(null_mut())?;
    if mime == "." {
        let mut names = BTreeSet::new();
        let png = register("PNG");
        let mut format = 0;
        loop {
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                break;
            }
            if format == UNICODE_TEXT {
                names.insert("text/plain".to_owned());
            }
            if png != 0 && format == png {
                names.insert("image/png".to_owned());
            }
            let mut name = [0u16; 256];
            let count =
                unsafe { GetClipboardFormatNameW(format, name.as_mut_ptr(), name.len() as i32) };
            if count > 0 {
                let text = String::from_utf16_lossy(&name[..count as usize]);
                if let Some(name) = text
                    .strip_prefix(MIME_PREFIX)
                    .filter(|name| valid_mime(name))
                {
                    names.insert(name.to_owned());
                }
            }
        }
        return Some(names.into_iter().collect::<Vec<_>>().join(" ").into_bytes());
    }
    if !valid_mime(mime) {
        return None;
    }
    if let Some(framed) = bytes(register(&format!("{MIME_PREFIX}{mime}"))) {
        let length = usize::try_from(u64::from_le_bytes(framed.get(..8)?.try_into().ok()?)).ok()?;
        if length > LIMIT {
            return None;
        }
        return Some(framed.get(8..8usize.checked_add(length)?)?.to_vec());
    }
    if mime == "text/plain" {
        let raw = bytes(UNICODE_TEXT)?;
        let text: Vec<u16> = raw
            .chunks_exact(2)
            .map(|v| u16::from_le_bytes([v[0], v[1]]))
            .take_while(|v| *v != 0)
            .collect();
        return String::from_utf16(&text).ok().map(String::into_bytes);
    }
    if mime == "image/png" {
        let raw = bytes(register("PNG"))?;
        if !raw.starts_with(b"\x89PNG\r\n\x1a\n") {
            return None;
        }
        let mut offset = 8usize;
        loop {
            let length =
                u32::from_be_bytes(raw.get(offset..offset.checked_add(4)?)?.try_into().ok()?)
                    as usize;
            let end = offset.checked_add(12)?.checked_add(length)?;
            if end > raw.len() {
                return None;
            }
            if raw.get(offset + 4..offset + 8)? == b"IEND" && length == 0 {
                return Some(raw[..end].to_vec());
            }
            offset = end;
        }
    }
    None
}
