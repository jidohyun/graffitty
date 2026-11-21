//! Adapter for tests/chromium/chromium_linux_backend_e2e.py using the server receiver.
#![cfg(target_os = "linux")]

use graffitty_chromium_video::surface::Receiver;
use std::ffi::{CStr, c_char};

#[unsafe(no_mangle)]
unsafe extern "C" fn gft_linux_capture_new(endpoint: *const c_char) -> *mut Receiver {
    unsafe { CStr::from_ptr(endpoint) }
        .to_str()
        .ok()
        .and_then(|endpoint| Receiver::new(endpoint).ok())
        .map_or(std::ptr::null_mut(), |receiver| {
            Box::into_raw(Box::new(receiver))
        })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn gft_linux_capture_free(receiver: *mut Receiver) {
    unsafe { drop(Box::from_raw(receiver)) }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn gft_linux_capture_sample(
    receiver: *mut Receiver,
    width: *mut u32,
    height: *mut u32,
    rgba: *mut u8,
) -> i32 {
    let Some(surface) = (unsafe { &mut *receiver }).receive() else {
        return 0;
    };
    if surface.is_software_paint()
        && matches!(
            std::env::var("GRAFFITTY_CAPTURE").as_deref(),
            Ok("vulkan" | "cuda")
        )
    {
        return -1;
    }
    let Ok(pixels) = surface.rgba() else {
        return -1;
    };
    let center = ((surface.height / 2 * surface.width + surface.width / 2) * 4) as usize;
    unsafe {
        *width = surface.width;
        *height = surface.height;
        std::ptr::copy_nonoverlapping(pixels.as_ptr().add(center), rgba, 4);
    }
    1
}
