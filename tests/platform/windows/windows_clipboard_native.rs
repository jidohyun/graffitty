//! Standalone native adapter check on a PRIVATE window station and desktop.
//! Compile with rustc; never invoke clipboard APIs unless isolation succeeds.
#[path = "../../../crates/platform/src/clipboard_windows.rs"]
mod clipboard;
use std::{collections::BTreeMap, ffi::c_void, ptr::null_mut, sync::Arc};
type Handle = *mut c_void;
#[link(name = "user32")]
unsafe extern "system" {
    fn GetProcessWindowStation() -> Handle;
    fn CreateWindowStationW(name: *const u16, flags: u32, access: u32, security: Handle) -> Handle;
    fn SetProcessWindowStation(station: Handle) -> i32;
    fn CloseWindowStation(station: Handle) -> i32;
    fn GetThreadDesktop(thread: u32) -> Handle;
    fn CreateDesktopW(
        name: *const u16,
        device: *const u16,
        mode: Handle,
        flags: u32,
        access: u32,
        security: Handle,
    ) -> Handle;
    fn SetThreadDesktop(desktop: Handle) -> i32;
    fn CloseDesktop(desktop: Handle) -> i32;
    fn IsClipboardFormatAvailable(format: u32) -> i32;
    fn RegisterClipboardFormatW(name: *const u16) -> u32;
    fn CreateWindowExW(ex: u32, class: *const u16, title: *const u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: Handle, menu: Handle, instance: Handle, param: Handle) -> Handle;
    fn DestroyWindow(window: Handle) -> i32;
    fn OpenClipboard(window: Handle) -> i32;
    fn EmptyClipboard() -> i32;
    fn SetClipboardData(format: u32, data: Handle) -> Handle;
    fn CloseClipboard() -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentThreadId() -> u32;
    fn GlobalAlloc(flags: u32, bytes: usize) -> Handle;
    fn GlobalLock(memory: Handle) -> Handle;
    fn GlobalUnlock(memory: Handle) -> i32;
}
fn external_write(formats: &[(u32, Vec<u8>)]) {
    unsafe {
        let window = CreateWindowExW(0, wide("STATIC").as_ptr(), wide("").as_ptr(), 0, 0, 0, 0, 0, -3isize as Handle, null_mut(), null_mut(), null_mut());
        assert!(!window.is_null());
        assert_ne!(OpenClipboard(window), 0);
        assert_ne!(EmptyClipboard(), 0);
        for (format, bytes) in formats {
            let memory = GlobalAlloc(0x42, bytes.len() + 16);
            assert!(!memory.is_null());
            let pointer = GlobalLock(memory);
            assert!(!pointer.is_null());
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer.cast::<u8>(), bytes.len());
            GlobalUnlock(memory);
            assert!(!SetClipboardData(*format, memory).is_null());
        }
        CloseClipboard();
        DestroyWindow(window);
    }
}
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
struct Isolation {
    station: Handle,
    desktop: Handle,
    original_station: Handle,
    original_desktop: Handle,
}
impl Isolation {
    fn new() -> Self {
        unsafe {
            let original_station = GetProcessWindowStation();
            let original_desktop = GetThreadDesktop(GetCurrentThreadId());
            let station = CreateWindowStationW(
                wide(&format!("GraffittyClipboardTest{}", std::process::id())).as_ptr(),
                0,
                0xf037f,
                null_mut(),
            );
            assert!(
                !station.is_null(),
                "Private window station creation failed: {}",
                std::io::Error::last_os_error()
            );
            assert_ne!(
                SetProcessWindowStation(station),
                0,
                "Cannot isolate clipboard"
            );
            let desktop = CreateDesktopW(
                wide("ClipboardTest").as_ptr(),
                std::ptr::null(),
                null_mut(),
                0,
                0xf01ff,
                null_mut(),
            );
            assert!(!desktop.is_null(), "Private desktop creation failed");
            assert_ne!(
                SetThreadDesktop(desktop),
                0,
                "Cannot select private desktop"
            );
            assert_ne!(
                GetProcessWindowStation(),
                original_station,
                "Must not touch the user's clipboard"
            );
            Self {
                station,
                desktop,
                original_station,
                original_desktop,
            }
        }
    }
}
impl Drop for Isolation {
    fn drop(&mut self) {
        unsafe {
            SetThreadDesktop(self.original_desktop);
            SetProcessWindowStation(self.original_station);
            CloseDesktop(self.desktop);
            CloseWindowStation(self.station);
        }
    }
}
fn main() {
    let png = std::fs::read(std::env::args().nth(1).expect("PNG fixture required")).unwrap();
    assert!(png.len() > 128 * 1024);
    let _private = Isolation::new();
    let text = "Unicode 🏰 café 한글\r\nexact text".as_bytes().to_vec();
    let binary = vec![1, 2, 0, 255, 0, 0];
    let data = BTreeMap::from([
        ("text/plain".to_owned(), Arc::new(text.clone())),
        ("image/png".to_owned(), Arc::new(png.clone())),
        (
            "application/x-graffitty-fixture".to_owned(),
            Arc::new(binary.clone()),
        ),
        (
            "application/x-graffitty-alias".to_owned(),
            Arc::new(png.clone()),
        ),
    ]);
    assert!(clipboard::write(&data), "Native rich write failed");
    assert_eq!(clipboard::get("text/plain"), Some(text.clone()));
    assert_eq!(clipboard::get("image/png"), Some(png.clone()));
    assert_eq!(
        clipboard::get("application/x-graffitty-fixture"),
        Some(binary)
    );
    assert_eq!(clipboard::get("application/x-graffitty-alias"), Some(png.clone()));
    assert_eq!(
        clipboard::get("."),
        Some(
            data.keys()
                .cloned()
                .collect::<Vec<_>>()
                .join(" ")
                .into_bytes()
        )
    );
    unsafe {
        assert_ne!(
            IsClipboardFormatAvailable(13),
            0,
            "Native Unicode companion missing"
        );
        assert_ne!(
            IsClipboardFormatAvailable(RegisterClipboardFormatW(wide("PNG").as_ptr())),
            0,
            "Native PNG companion missing"
        );
    }
    assert!(!clipboard::write(&BTreeMap::from([(
        "bad\0format".into(),
        Arc::new(vec![1])
    )])));
    assert_eq!(clipboard::get("text/plain"), Some(text));
    assert!(clipboard::write(&BTreeMap::from([(
        "text/plain".into(),
        Arc::new(b"replacement".to_vec())
    )])));
    assert_eq!(
        clipboard::get("image/png"),
        None,
        "New text must remove stale formats"
    );
    assert_eq!(clipboard::get("."), Some(b"text/plain".to_vec()));
    let external_text = "External Unicode 🏰 café";
    let unicode: Vec<u8> = wide(external_text).into_iter().flat_map(u16::to_le_bytes).collect();
    let png_format = unsafe { RegisterClipboardFormatW(wide("PNG").as_ptr()) };
    external_write(&[(13, unicode), (png_format, png.clone())]);
    assert_eq!(clipboard::get("text/plain"), Some(external_text.as_bytes().to_vec()));
    assert_eq!(clipboard::get("image/png"), Some(png), "Native PNG allocation padding must be removed");
    assert_eq!(clipboard::get("."), Some(b"image/png text/plain".to_vec()));
    println!(
        "PASS private Windows clipboard: Unicode, PNG >128KiB, exact MIME/aliases/trailing NULs, enumeration, native formats, rejected-write preservation, replacement cleanup, external-only Unicode/PNG with allocation padding"
    );
}
