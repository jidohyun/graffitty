use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use std::ffi::c_void;
#[cfg(not(windows))]
use std::ffi::CString;
#[cfg(any(target_os = "macos", windows))]
use std::sync::Mutex;

unsafe extern "C" {
    #[cfg(not(windows))]
    fn graffitty_gpu_receiver_create(name: *const std::ffi::c_char) -> *mut c_void;
    #[cfg(not(windows))]
    fn graffitty_gpu_receiver_destroy(receiver: *mut c_void);
    #[cfg(not(any(target_os = "linux", windows)))]
    fn graffitty_gpu_receive(
        receiver: *mut c_void,
        device: u64,
        width: *mut u32,
        height: *mut u32,
        bgra: *mut u32,
        sequence: *mut u64,
    ) -> u64;
    #[cfg(target_os = "linux")]
    fn graffitty_gpu_receive_linux(
        receiver: *mut c_void,
        physical: u64,
        device: u64,
        queue: u64,
        family: u32,
        width: *mut u32,
        height: *mut u32,
        bgra: *mut u32,
        sequence: *mut u64,
    ) -> u64;
    #[cfg(target_os = "linux")]
    fn graffitty_gpu_release_frame(receiver: *mut c_void, sequence: u64);
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct ChromiumGpuReceiver {
    base: Base<RefCounted>,
    receiver: usize,
    #[cfg(any(target_os = "macos", windows))]
    shared: Mutex<Option<(graffitty_chromium_video::shared_gpu::Receiver, u32)>>,
}
#[godot_api]
impl IRefCounted for ChromiumGpuReceiver {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base, receiver: 0,
            #[cfg(any(target_os = "macos", windows))]
            shared: Mutex::new(None),
        }
    }
}
#[godot_api]
impl ChromiumGpuReceiver {
    /// Only a kernel-authenticated socket peer may enable native import.
    #[func]
    fn start_shared(&mut self, expected_server_pid: i64) -> GString {
        #[cfg(target_os = "macos")]
        {
            let Ok(pid) = u32::try_from(expected_server_pid) else { return GString::new(); };
            if pid == 0 || self.receiver != 0 { return GString::new(); }
            let Ok(receiver) = graffitty_chromium_video::shared_gpu::Receiver::new() else { return GString::new(); };
            let endpoint = receiver.endpoint().to_owned();
            *self.shared.lock().unwrap() = Some((receiver, pid));
            endpoint.as_str().into()
        }
        #[cfg(windows)]
        {
            let Ok(pid) = u32::try_from(expected_server_pid) else { return GString::new(); };
            if pid == 0 || self.receiver != 0 { return GString::new(); }
            let endpoint = format!(r"\\.\pipe\graffitty-gpu-{}", godot::classes::Crypto::new_gd().generate_random_bytes(16).hex_encode());
            let Ok(receiver) = graffitty_chromium_video::shared_gpu::Receiver::new(&endpoint) else { return GString::new(); };
            *self.shared.lock().unwrap() = Some((receiver, pid));
            endpoint.as_str().into()
        }
        #[cfg(not(any(target_os = "macos", windows)))]
        { let _ = expected_server_pid; GString::new() }
    }

    #[func]
    fn bind_lifetime(&self, destination: i64) -> bool {
        #[cfg(windows)]
        {
            if let Some((receiver, _)) = self.shared.lock().unwrap().as_ref() {
                return unsafe { receiver.bind_lifetime(destination as u64) };
            }
            false
        }
        #[cfg(not(windows))]
        {
            let _ = destination;
            true
        }
    }
    #[cfg(not(windows))]
    #[func]
    fn start(&mut self, endpoint: GString) -> bool {
        if self.receiver != 0 {
            return false;
        }
        let Ok(name) = CString::new(endpoint.to_string()) else {
            return false;
        };
        self.receiver = unsafe { graffitty_gpu_receiver_create(name.as_ptr()) } as usize;
        self.receiver != 0
    }
    // Only called on Godot's render thread. Returns an owned native texture,
    // never pixels. The caller must immediately import it into RenderingDevice.
    #[cfg(not(target_os = "linux"))]
    #[func]
    fn receive(&self, device: i64) -> VarDictionary {
        #[cfg(windows)]
        if let Some((receiver, pid)) = self.shared.lock().unwrap().as_mut() {
            use graffitty_chromium_video::shared_gpu::Received;
            let mut result = VarDictionary::new();
            match unsafe { receiver.receive(*pid, device as *mut c_void) } {
                Ok(None) => {},
                Err(error) => { result.set("error", error.as_str()); },
                Ok(Some(Received::Probe)) => { result.set("probe", true); },
                Ok(Some(Received::Frame{handle, width, height, bgra, sequence})) => {
                    result.set("handle", handle as i64); result.set("width", width);
                    result.set("height", height); result.set("bgra", bgra); result.set("sequence", sequence as i64);
                }
            }
            return result;
        }
        #[cfg(target_os = "macos")]
        if let Some((receiver, pid)) = self.shared.lock().unwrap().as_mut() {
            let mut result = VarDictionary::new();
            let frame = match receiver.receive(*pid) {
                Ok(Some(frame)) => frame,
                Ok(None) => return result,
                Err(error) => { result.set("error", error.as_str()); return result; }
            };
            let mut frame = frame;
            let device = device as *mut c_void;
            if frame.is_probe {
                match unsafe { frame.prove(device) } {
                    Ok(()) => result.set("probe", true),
                    Err(error) => result.set("error", error.as_str()),
                }
            } else {
                match unsafe { frame.surface.metal_texture(device) } {
                    Ok(texture) => {
                        // Godot's Metal external wrapper takes this +1 texture.
                        // The texture retains its IOSurface through queued draws.
                        result.set("handle", texture as i64);
                        result.set("width", frame.surface.width);
                        result.set("height", frame.surface.height);
                        result.set("bgra", true);
                        result.set("sequence", frame.sequence as i64);
                    }
                    Err(error) => result.set("error", error.as_str()),
                }
            }
            return result;
        }
        #[cfg(not(windows))]
        {
        let (mut width, mut height, mut bgra, mut sequence) = (0, 0, 0, 0);
        let handle = unsafe {
            graffitty_gpu_receive(
                self.receiver as *mut c_void,
                device as u64,
                &mut width,
                &mut height,
                &mut bgra,
                &mut sequence,
            )
        };
        let mut result = VarDictionary::new();
        if handle != 0 {
            result.set("handle", handle as i64);
            result.set("width", width);
            result.set("height", height);
            result.set("bgra", bgra != 0);
            result.set("sequence", sequence as i64);
        }
        result
        }
        #[cfg(windows)]
        { VarDictionary::new() }
    }
    #[cfg(target_os = "linux")]
    #[func]
    fn receive_linux(&self, physical: i64, device: i64, queue: i64, family: i64) -> VarDictionary {
        let (mut width, mut height, mut bgra, mut sequence) = (0, 0, 0, 0);
        let address = unsafe {
            graffitty_gpu_receive_linux(
                self.receiver as *mut c_void,
                physical as u64,
                device as u64,
                queue as u64,
                family as u32,
                &mut width,
                &mut height,
                &mut bgra,
                &mut sequence,
            )
        };
        let mut result = VarDictionary::new();
        if address != 0 {
            result.set("address", address as i64);
            result.set("width", width);
            result.set("height", height);
            result.set("bgra", bgra != 0);
            result.set("sequence", sequence as i64);
        }
        result
    }
    // Called after a four-byte Godot buffer_get_data_async completion. Its
    // dependency on the compute dispatch covers every source-buffer read.
    #[cfg(target_os = "linux")]
    #[func]
    fn release_frame(&self, sequence: i64) {
        unsafe { graffitty_gpu_release_frame(self.receiver as *mut c_void, sequence as u64) };
    }
}
impl Drop for ChromiumGpuReceiver {
    fn drop(&mut self) {
        #[cfg(not(windows))]
        unsafe { graffitty_gpu_receiver_destroy(self.receiver as *mut c_void) };
    }
}
