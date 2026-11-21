//! Shared macOS MIME clipboard provider; callers enforce permission policy.
unsafe extern "C" {
    fn graffitty_clipboard_clear();
    fn graffitty_clipboard_set(mime: *const std::ffi::c_char, data: *const u8, size: usize)
    -> bool;
    fn graffitty_clipboard_get(mime: *const std::ffi::c_char, size: *mut usize) -> *mut u8;
    fn graffitty_clipboard_free(data: *mut std::ffi::c_void);
}
pub fn get(mime: &str) -> Option<Vec<u8>> {
    let name = std::ffi::CString::new(mime).ok()?;
    let mut size = 0;
    unsafe {
        let ptr = graffitty_clipboard_get(name.as_ptr(), &mut size);
        if ptr.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(ptr, size).to_vec();
        graffitty_clipboard_free(ptr.cast());
        Some(bytes)
    }
}
pub fn write(data: &crate::clipboard_core::Data) -> bool {
    let names: Option<Vec<_>> = data
        .keys()
        .map(|mime| std::ffi::CString::new(mime.as_str()).ok())
        .collect();
    let Some(names) = names else {
        return false;
    };
    unsafe {
        graffitty_clipboard_clear();
    }
    data.values().zip(names).all(|(data, mime)| unsafe {
        graffitty_clipboard_set(mime.as_ptr(), data.as_ptr(), data.len())
    })
}
