//! Connection-bound Mach rights transport for immutable chromium textures.
//!
//! A fresh IOSurface challenge must be imported on the client's render
//! device. Its native reply is checked against the Unix socket peer's kernel
//! PID.
//!
//! A byte relay therefore cannot turn a remote connection into a local GPU
//! connection.
use crate::surface::Surface;
use std::ffi::{CStr, CString, c_char, c_void};
use std::time::{Duration, Instant};
unsafe extern "C" {
    fn gg_peer_pid(fd: i32) -> i32;
    fn gg_receiver_new(name: *mut c_char, size: usize) -> *mut c_void;
    fn gg_receiver_free(receiver: *mut c_void);
    fn gg_channel_new(endpoint: *const c_char, peer: i32) -> *mut c_void;
    fn gg_channel_free(channel: *mut c_void);
    fn gg_channel_confirm(channel: *mut c_void) -> i32;
    fn gg_channel_send(channel: *mut c_void, surface: *mut c_void, sequence: u64) -> i32;
    fn gg_receive(receiver: *mut c_void, server: i32, error: *mut i32) -> *mut c_void;
    fn gg_receiver_pending(receiver: *mut c_void) -> i32;
    fn gg_frame_free(frame: *mut c_void);
    fn gg_frame_surface(
        frame: *mut c_void,
        width: *mut u32,
        height: *mut u32,
        sequence: *mut u64,
        probe: *mut i32,
    ) -> *mut c_void;
    fn gg_frame_prove(frame: *mut c_void, device: *mut c_void) -> i32;
    fn gg_default_device() -> *mut c_void;
    fn gg_object_free(object: *mut c_void);
}
/// The kernel identity of the connected Unix peer, never a descriptor's claim.
pub fn peer_pid(fd: i32) -> Option<u32> {
    let pid = unsafe { gg_peer_pid(fd) };
    (pid > 0).then_some(pid as u32)
}
pub struct Receiver {
    handle: *mut c_void,
    endpoint: String,
}
unsafe impl Send for Receiver {}
impl Receiver {
    pub fn new() -> Result<Self, String> {
        let mut name = [0i8; 256];
        let handle = unsafe { gg_receiver_new(name.as_mut_ptr(), name.len()) };
        if handle.is_null() {
            return Err("Cannot register client GPU endpoint".into());
        }
        let endpoint = unsafe { CStr::from_ptr(name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        Ok(Self { handle, endpoint })
    }
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }
    /// The receive port's name, for `frame_pending` on a wakeup thread.
    pub fn port(&self) -> u32 {
        self.handle as usize as u32
    }
    pub fn receive(&mut self, expected_server_pid: u32) -> Result<Option<Frame>, String> {
        let mut error = 0;
        let handle = unsafe { gg_receive(self.handle, expected_server_pid as i32, &mut error) };
        if error != 0 {
            return Err("Invalid GPU frame or mismatched socket peer".into());
        }
        if handle.is_null() {
            return Ok(None);
        }
        let (mut width, mut height, mut sequence, mut probe) = (0, 0, 0, 0);
        let surface =
            unsafe { gg_frame_surface(handle, &mut width, &mut height, &mut sequence, &mut probe) };
        Ok(Some(Frame {
            handle,
            surface: Surface {
                handle: surface,
                width,
                height,
            },
            sequence,
            is_probe: probe != 0,
        }))
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        unsafe { gg_receiver_free(self.handle) };
    }
}
pub struct Frame {
    handle: *mut c_void,
    pub surface: Surface,
    pub sequence: u64,
    pub is_probe: bool,
}
unsafe impl Send for Frame {}
impl Frame {
    /// Import and sample the challenge on the actual renderer's Metal device,
    /// then transfer proof via the native reply right received with the surface.
    ///
    /// # Safety
    /// `device` must be a live Objective-C MTLDevice for the duration of this call.
    pub unsafe fn prove(&mut self, device: *mut c_void) -> Result<(), String> {
        if unsafe { gg_frame_prove(self.handle, device) } != 0 {
            return Err("GPU probe import or native proof delivery failed".into());
        }
        Ok(())
    }
}
impl Drop for Frame {
    fn drop(&mut self) {
        unsafe { gg_frame_free(self.handle) };
    }
}
/// Server-side channel; no frames are sent until the challenge is verified.
pub struct Channel {
    handle: *mut c_void,
    started: Instant,
    active: bool,
}
unsafe impl Send for Channel {}
impl Channel {
    pub fn new(endpoint: &str, peer_pid: u32) -> Result<Self, String> {
        let endpoint = CString::new(endpoint).map_err(|_| "Invalid GPU endpoint")?;
        let handle = unsafe { gg_channel_new(endpoint.as_ptr(), peer_pid as i32) };
        if handle.is_null() {
            return Err("Native GPU resource exchange unavailable".into());
        }
        Ok(Self {
            handle,
            started: Instant::now(),
            active: false,
        })
    }
    pub fn confirm(&mut self) -> Result<bool, String> {
        if !self.active && self.started.elapsed() > Duration::from_secs(5) {
            return Err("GPU probe expired; negotiate again".into());
        }
        match unsafe { gg_channel_confirm(self.handle) } {
            1 => {
                self.active = true;
                Ok(true)
            }
            0 => Ok(false),
            _ => Err("GPU import proof does not match this connection".into()),
        }
    }
    pub fn active(&self) -> bool {
        self.active
    }
    /// Queue at most two native frames. Full mailbox means drop/retry latest;
    /// a disconnected destination instead causes portable video fallback.
    pub fn send(&self, surface: &Surface, sequence: u64) -> Result<bool, String> {
        match unsafe { gg_channel_send(self.handle, surface.handle, sequence) } {
            1 => Ok(true),
            0 => Ok(false),
            _ => Err("Client GPU endpoint disconnected".into()),
        }
    }
}
impl Drop for Channel {
    fn drop(&mut self) {
        unsafe { gg_channel_free(self.handle) };
    }
}
/// Standalone native import probe for conformance tools. Frontends supply their
/// existing renderer device to `Frame::prove` instead of creating this device.
pub struct ProbeDevice(*mut c_void);
impl ProbeDevice {
    pub fn new() -> Result<Self, String> {
        let device = unsafe { gg_default_device() };
        if device.is_null() {
            Err("Metal device unavailable".into())
        } else {
            Ok(Self(device))
        }
    }
    pub fn as_ptr(&self) -> *mut c_void {
        self.0
    }
}
impl Drop for ProbeDevice {
    fn drop(&mut self) {
        unsafe { gg_object_free(self.0) };
    }
}

/// Whether a frame is queued on this receive port (see `Receiver::port`).
/// Thread-safe; it never consumes the frame.
pub fn frame_pending(port: u32) -> bool {
    port != 0 && unsafe { gg_receiver_pending(port as usize as *mut c_void) } != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" {
        static mach_task_self_: u32;
        fn mach_port_names(task: u32, names: *mut *mut u32, names_count: *mut u32,
            types: *mut *mut u32, types_count: *mut u32) -> i32;
        fn vm_deallocate(task: u32, address: usize, size: usize) -> i32;
    }

    fn port_names() -> u32 {
        unsafe {
            let (mut names, mut types) = (std::ptr::null_mut(), std::ptr::null_mut());
            let (mut names_count, mut types_count) = (0, 0);
            assert_eq!(mach_port_names(mach_task_self_, &mut names, &mut names_count, &mut types, &mut types_count), 0);
            vm_deallocate(mach_task_self_, names as usize, names_count as usize * 4);
            vm_deallocate(mach_task_self_, types as usize, types_count as usize * 4);
            names_count
        }
    }

    /// A client that stops draining (in the background, or busy) fills its
    /// two-frame queue, and every later send times out.
    ///
    /// Each leaked right kept a whole captured frame alive: a live server
    /// reached 67 thousand.
    #[test]
    fn a_client_that_stops_draining_leaks_no_frame_rights() {
        let mut receiver = Receiver::new().unwrap();
        let pid = std::process::id();
        let mut channel = Channel::new(receiver.endpoint(), pid).unwrap();
        let device = ProbeDevice::new().unwrap();
        let mut probe = receiver.receive(pid).unwrap().expect("challenge frame");
        unsafe { probe.prove(device.0) }.unwrap();
        drop(probe);
        let deadline = Instant::now() + Duration::from_secs(2);
        while !channel.confirm().unwrap() {
            assert!(Instant::now() < deadline, "challenge confirmed");
            std::thread::sleep(Duration::from_millis(1));
        }
        let surface = Surface::from_rgba(64, 64, &vec![255; 64 * 64 * 4]).unwrap();
        let before = port_names();
        let dropped = (1..=200).filter(|&sequence| !channel.send(&surface, sequence).unwrap()).count();
        assert!(dropped >= 190, "the client's queue filled: {dropped} of 200 dropped");
        // Metal and IOSurface threads release a port or two meanwhile; the old
        // leak added one name per dropped frame.
        let after = port_names();
        assert!(after <= before + 4, "timed-out sends left rights behind: {before} -> {after} names");
    }
}
