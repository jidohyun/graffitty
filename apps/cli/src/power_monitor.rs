//! OS power-source events. A private helper isolates native event loops from Godot.
use serde_json::json;
use std::io::{self, Write};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn emit(state: Option<bool>) -> io::Result<()> {
    let mut out = io::stdout().lock();
    writeln!(
        out,
        "{}",
        json!({"available":state.is_some(), "on_battery":state.unwrap_or(false)})
    )?;
    out.flush()
}

pub fn run(watch: bool) -> Result<()> {
    if watch {
        // The host closes/kills the helper on exit. EOF also prevents orphan
        // watchers when the parent exits unexpectedly, without periodic polling.
        std::thread::spawn(|| {
            let mut input = String::new();
            let _ = io::stdin().read_line(&mut input);
            std::process::exit(0);
        });
        if let Err(error) = platform::watch() {
            let _ = emit(None);
            return Err(error);
        }
        Ok(())
    } else {
        emit(platform::current()?)?;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::ffi::{c_char, c_void};
    type Ref = *const c_void;
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> Ref;
        fn IOPSGetProvidingPowerSourceType(info: Ref) -> Ref;
        fn IOPSNotificationCreateRunLoopSource(
            callback: extern "C" fn(*mut c_void),
            context: *mut c_void,
        ) -> Ref;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(value: Ref);
        fn CFStringGetCString(value: Ref, buffer: *mut c_char, size: isize, encoding: u32) -> bool;
        fn CFRunLoopGetCurrent() -> Ref;
        fn CFRunLoopAddSource(run_loop: Ref, source: Ref, mode: Ref);
        fn CFRunLoopRun();
        static kCFRunLoopDefaultMode: Ref;
    }
    pub fn current() -> Result<Option<bool>> {
        unsafe {
            let info = IOPSCopyPowerSourcesInfo();
            if info.is_null() {
                return Ok(None);
            }
            let source = IOPSGetProvidingPowerSourceType(info);
            let mut bytes = [0u8; 128];
            let valid = !source.is_null()
                && CFStringGetCString(
                    source,
                    bytes.as_mut_ptr().cast(),
                    bytes.len() as isize,
                    0x08000100,
                );
            CFRelease(info);
            Ok(if valid {
                match std::ffi::CStr::from_bytes_until_nul(&bytes)?.to_str()? {
                    "Battery Power" | "UPS Power" => Some(true),
                    "AC Power" => Some(false),
                    _ => None,
                }
            } else {
                None
            })
        }
    }
    extern "C" fn changed(_: *mut c_void) {
        if emit(current().ok().flatten()).is_err() {
            std::process::exit(0);
        }
    }
    pub fn watch() -> Result<()> {
        unsafe {
            let source = IOPSNotificationCreateRunLoopSource(changed, std::ptr::null_mut());
            if source.is_null() {
                return Err("Could not subscribe to IOKit power events".into());
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
            // Subscribe before reading so a change during startup cannot be lost.
            emit(current()?)?;
            CFRunLoopRun();
            CFRelease(source);
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use zbus::blocking::{Connection, Proxy};
    fn connect() -> Result<Connection> {
        Ok(zbus::blocking::connection::Builder::system()?
            .method_timeout(std::time::Duration::from_secs(2))
            .build()?)
    }
    fn proxy(connection: &Connection) -> zbus::Result<Proxy<'_>> {
        Proxy::new(
            connection,
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower",
            "org.freedesktop.UPower",
        )
    }
    pub fn current() -> Result<Option<bool>> {
        let connection = connect()?;
        Ok(Some(proxy(&connection)?.get_property("OnBattery")?))
    }
    pub fn watch() -> Result<()> {
        let connection = connect()?;
        let proxy = proxy(&connection)?;
        let changes = proxy.receive_property_changed::<bool>("OnBattery");
        emit(Some(proxy.get_property("OnBattery")?))?;
        for event in changes {
            emit(event.get().ok())?;
        }
        Err("UPower event stream closed".into())
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use windows_sys::Win32::{System::Power::*, UI::WindowsAndMessaging::DEVICE_NOTIFY_CALLBACK};
    const AC_DC: windows_sys::core::GUID =
        windows_sys::core::GUID::from_u128(0x5d3e9a59_e9d5_4b00_a6bd_ff34ff516548);
    // Serialize the initial snapshot with callbacks so an older reading cannot
    // be emitted after a newer one from the OS callback thread.
    static SNAPSHOT: std::sync::Mutex<()> = std::sync::Mutex::new(());
    fn snapshot() -> io::Result<()> {
        let _guard = SNAPSHOT.lock().unwrap();
        emit(current().ok().flatten())
    }
    pub fn current() -> Result<Option<bool>> {
        let mut status = SYSTEM_POWER_STATUS::default();
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
            return Err(io::Error::last_os_error().into());
        }
        Ok(match status.ACLineStatus {
            0 => Some(true),
            1 => Some(false),
            _ => None,
        })
    }
    unsafe extern "system" fn changed(
        _: *const std::ffi::c_void,
        _: u32,
        _: *const std::ffi::c_void,
    ) -> u32 {
        if snapshot().is_err() {
            std::process::exit(0);
        }
        0
    }
    pub fn watch() -> Result<()> {
        let mut subscription = DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
            Callback: Some(changed),
            Context: std::ptr::null_mut(),
        };
        let mut handle = std::ptr::null_mut();
        let result = unsafe {
            PowerSettingRegisterNotification(
                &AC_DC,
                DEVICE_NOTIFY_CALLBACK,
                (&mut subscription as *mut DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS).cast(),
                &mut handle,
            )
        };
        if result != 0 {
            return Err(io::Error::from_raw_os_error(result as i32).into());
        }
        snapshot()?;
        // Native callbacks run on the OS's callback thread. No message pump or polling.
        loop {
            std::thread::park();
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
mod platform {
    use super::*;
    pub fn current() -> Result<Option<bool>> {
        Ok(None)
    }
    pub fn watch() -> Result<()> {
        emit(None)?;
        Ok(())
    }
}
