//! Connection-bound Windows shared textures with proof on the renderer device.
use crate::surface::Surface;
use std::{
    ffi::{CString, c_void},
    time::{Duration, Instant},
};
unsafe extern "C" {
    fn gw_channel_new(endpoint: *const i8, pid: u32) -> *mut c_void;
    fn gw_channel_free(p: *mut c_void);
    fn gw_channel_confirm(p: *mut c_void) -> i32;
    fn gw_channel_send(p: *mut c_void, surface: *mut c_void, sequence: u64) -> i32;
    fn gw_receiver_new(endpoint: *const i8) -> *mut c_void;
    fn gw_receiver_free(p: *mut c_void);
    fn gw_receive(
        p: *mut c_void,
        pid: u32,
        device: *mut c_void,
        texture: *mut u64,
        width: *mut u32,
        height: *mut u32,
        bgra: *mut u32,
        sequence: *mut u64,
    ) -> i32;
    fn gw_bind_lifetime(p: *mut c_void, destination: u64) -> bool;
}
pub struct Channel {
    handle: *mut c_void,
    started: Instant,
    active: bool,
}
unsafe impl Send for Channel {}
impl Channel {
    pub fn new(endpoint: &str, pid: u32) -> Result<Self, String> {
        let name = CString::new(endpoint).map_err(|_| "Invalid GPU endpoint")?;
        let handle = unsafe { gw_channel_new(name.as_ptr(), pid) };
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
        if self.active {
            return Ok(true);
        }
        if self.started.elapsed() > Duration::from_secs(5) {
            return Err("GPU proof expired".into());
        }
        match unsafe { gw_channel_confirm(self.handle) } {
            1 => {
                self.active = true;
                Ok(true)
            }
            0 => Ok(false),
            _ => Err("GPU device proof does not match connection".into()),
        }
    }
    pub fn active(&self) -> bool {
        self.active
    }
    pub fn send(&self, surface: &Surface, sequence: u64) -> Result<bool, String> {
        match unsafe { gw_channel_send(self.handle, surface.handle, sequence) } {
            1 => Ok(true),
            0 => Ok(false),
            _ => Err("Native GPU channel failed".into()),
        }
    }
}
impl Drop for Channel {
    fn drop(&mut self) {
        unsafe { gw_channel_free(self.handle) };
    }
}
pub struct Receiver {
    handle: *mut c_void,
}
unsafe impl Send for Receiver {}
pub enum Received {
    Probe,
    Frame {
        handle: u64,
        width: u32,
        height: u32,
        bgra: bool,
        sequence: u64,
    },
}
impl Receiver {
    pub fn new(endpoint: &str) -> Result<Self, String> {
        let name = CString::new(endpoint).map_err(|_| "Invalid GPU endpoint")?;
        let handle = unsafe { gw_receiver_new(name.as_ptr()) };
        if handle.is_null() {
            Err("Cannot register GPU receiver".into())
        } else {
            Ok(Self { handle })
        }
    }
    /// # Safety
    /// device must be a live renderer ID3D12Device on its rendering thread.
    pub unsafe fn receive(
        &mut self,
        pid: u32,
        device: *mut c_void,
    ) -> Result<Option<Received>, String> {
        let (mut handle, mut width, mut height, mut bgra, mut sequence) = (0, 0, 0, 0, 0);
        match unsafe {
            gw_receive(
                self.handle,
                pid,
                device,
                &mut handle,
                &mut width,
                &mut height,
                &mut bgra,
                &mut sequence,
            )
        } {
            0 => Ok(None),
            2 => Ok(Some(Received::Probe)),
            1 => Ok(Some(Received::Frame {
                handle,
                width,
                height,
                bgra: bgra != 0,
                sequence,
            })),
            _ => Err("Native GPU peer verification or D3D12 import failed".into()),
        }
    }
    /// # Safety
    /// destination must be a live Godot-owned ID3D12Resource.
    pub unsafe fn bind_lifetime(&self, destination: u64) -> bool {
        unsafe { gw_bind_lifetime(self.handle, destination) }
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        unsafe { gw_receiver_free(self.handle) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    unsafe extern "C" {
        fn gw_probe_device_new() -> *mut c_void;
        fn gw_probe_device_free(p: *mut c_void);
    }
    struct Device(*mut c_void);
    impl Drop for Device {
        fn drop(&mut self) {
            unsafe { gw_probe_device_free(self.0) };
        }
    }
    fn endpoint(label: &str) -> String {
        format!(
            r"\\.\pipe\graffitty-gpu-test-{}-{label}",
            std::process::id()
        )
    }
    #[test]
    fn actual_device_proof_and_kernel_peer_identity() {
        let name = endpoint("proof");
        let mut receiver = Receiver::new(&name).unwrap();
        assert!(
            Channel::new(&name, std::process::id() + 1).is_err(),
            "a descriptor PID must not override the kernel peer"
        );
        drop(receiver);
        receiver = Receiver::new(&name).unwrap();
        let mut channel = Channel::new(&name, std::process::id()).unwrap();
        assert!(
            !channel.confirm().unwrap(),
            "offering a texture alone is not proof"
        );
        let device = Device(unsafe { gw_probe_device_new() });
        assert!(!device.0.is_null(), "D3D12 test device required");
        assert!(matches!(
            unsafe { receiver.receive(std::process::id(), device.0) }.unwrap(),
            Some(Received::Probe)
        ));
        assert!(channel.confirm().unwrap());
        assert!(channel.active());
    }
    #[test]
    fn receiver_rejects_a_different_server_process() {
        let name = endpoint("server");
        let mut receiver = Receiver::new(&name).unwrap();
        let _channel = Channel::new(&name, std::process::id()).unwrap();
        let device = Device(unsafe { gw_probe_device_new() });
        assert!(!device.0.is_null());
        assert!(unsafe { receiver.receive(std::process::id() + 1, device.0) }.is_err());
    }
}
