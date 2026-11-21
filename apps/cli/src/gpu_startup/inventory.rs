//! Adapter inventory before engine startup. No rendering device is created here.
#[derive(Debug, Clone, Default)]
pub(super) struct Adapter {
    pub luid: Option<u64>,
    pub vendor_id: u32,
    pub device_id: u32,
    pub subsystem_id: u32,
    pub revision: u32,
    pub description: String,
    pub software: bool,
    pub has_outputs: bool,
    pub driver_version: Option<String>,
    pub dedicated_video_memory: u64,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub(super) enum Os {
    Windows,
    Linux,
}

#[derive(Debug)]
pub(super) struct Inventory {
    pub os: Os,
    /// On Windows these are in Godot D3D12 enumeration order.
    pub adapters: Vec<Adapter>,
    /// Index of DXGI EnumAdapters1(0), as in Chromium's CollectDriverInfoD3D.
    pub primary: Option<usize>,
    pub high_performance: Option<usize>,
    /// Godot's D3D12 selection. Vulkan enumerates VkPhysicalDevices and checks
    /// present queues itself, so its selected device cannot be inferred here.
    pub active: Option<usize>,
    linux_driver_state: Vec<String>,
}

impl Inventory {
    pub(super) fn new(os: Os) -> Self {
        Self {
            os,
            adapters: Vec::new(),
            primary: None,
            high_performance: None,
            active: None,
            linux_driver_state: Vec::new(),
        }
    }

    pub(super) fn fingerprint(&self) -> String {
        let mut rows = self.linux_driver_state.clone();
        for (i, gpu) in self.adapters.iter().enumerate() {
            rows.push(format!(
                "{:04x}:{:04x}:{:08x}:{:02x}\t{}\t{}",
                gpu.vendor_id,
                gpu.device_id,
                gpu.subsystem_id,
                gpu.revision,
                gpu.driver_version.as_deref().unwrap_or(""),
                self.active == Some(i)
            ));
        }
        rows.sort();
        rows.join("\n")
    }

    // Godot 4.7.2: rendering_context_driver_d3d12.cpp::_initialize_devices
    // and rendering_device.cpp::_get_device_type_score / initialize. D3D12
    // reports present support even for adapters with no attached output.
    #[cfg(any(windows, test))]
    pub(super) fn select_d3d12(&mut self, integrated: bool, index: Option<usize>) {
        self.active = index.filter(|&i| i < self.adapters.len()).or_else(|| {
            let mut best = None;
            let mut best_score = 0;
            for (i, gpu) in self.adapters.iter().enumerate() {
                let score = if gpu.software {
                    2
                } else if (gpu.dedicated_video_memory == 0) == integrated {
                    5
                } else {
                    4
                };
                if score > best_score {
                    best = Some(i);
                    best_score = score;
                }
            }
            best
        });
    }
}

#[cfg(any(windows, test))]
fn umd_version(raw: i64) -> String {
    let word = |shift: usize| (raw as u64 >> shift) & 0xffff;
    format!("{}.{}.{}.{}", word(48), word(32), word(16), word(0))
}

#[cfg(windows)]
fn prefers_integrated(runtime: &std::path::Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_SZ, RegGetValueW};
    // Godot OS_Windows::get_user_prefers_integrated_gpu reads the EXE's
    // registry value. The shipped runtime is an unpackaged Win32 executable.
    let Ok(path) = dunce::canonicalize(runtime) else {
        return false;
    };
    let name: Vec<_> = path.as_os_str().encode_wide().chain([0]).collect();
    let read = |buffer, size: &mut u32| unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            windows_sys::core::w!(r"SOFTWARE\Microsoft\DirectX\UserGpuPreferences"),
            name.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buffer,
            size,
        )
    };
    let mut bytes = 0;
    if read(std::ptr::null_mut(), &mut bytes) != 0 {
        return false;
    }
    let mut flags = vec![0u16; (bytes as usize).div_ceil(2)];
    read(flags.as_mut_ptr().cast(), &mut bytes) == 0
        && String::from_utf16_lossy(&flags)
            .trim_end_matches('\0')
            .split(';')
            .any(|f| f == "GpuPreference=1")
}

#[cfg(windows)]
pub(super) fn collect(runtime: &std::path::Path, gpu_index: Option<usize>) -> Inventory {
    use windows::Win32::Graphics::Dxgi::*;
    use windows::core::Interface;

    let mut result = Inventory::new(Os::Windows);
    // The typed COM interfaces own their references and DXGI initializes all
    // returned descriptors. LUIDs only correlate rows within this enumeration.
    unsafe {
        let Ok(factory) = CreateDXGIFactory1::<IDXGIFactory1>() else {
            return result;
        };
        let factory6 = factory.cast::<IDXGIFactory6>().ok();
        let primary = factory.EnumAdapters1(0).and_then(|a| a.GetDesc1()).ok();
        for i in 0.. {
            let adapter = match &factory6 {
                Some(f) => f.EnumAdapterByGpuPreference::<IDXGIAdapter1>(
                    i,
                    DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                ),
                None => factory.EnumAdapters1(i),
            };
            let adapter = match adapter {
                Ok(a) => a,
                Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                Err(_) => return result, // An incomplete enumeration cannot predict the active GPU.
            };
            let Ok(desc) = adapter.GetDesc1() else {
                return result;
            };
            let luid = desc.AdapterLuid;
            if primary.as_ref().is_some_and(|d| d.AdapterLuid == luid) {
                result.primary = Some(i as usize);
            }
            if i == 0 && factory6.is_some() {
                result.high_performance = Some(0);
            }
            let end = desc
                .Description
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(desc.Description.len());
            result.adapters.push(Adapter {
                luid: Some(((luid.HighPart as u64) << 32) | u64::from(luid.LowPart)),
                vendor_id: desc.VendorId,
                device_id: desc.DeviceId,
                subsystem_id: desc.SubSysId,
                revision: desc.Revision,
                description: String::from_utf16_lossy(&desc.Description[..end]),
                software: desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0,
                dedicated_video_memory: desc.DedicatedVideoMemory as u64,
                has_outputs: adapter.EnumOutputs(0).is_ok(),
                driver_version: adapter
                    .CheckInterfaceSupport(&IDXGIDevice::IID)
                    .ok()
                    .map(umd_version),
            });
        }
    }
    result.select_d3d12(prefers_integrated(runtime), gpu_index);
    result
}

#[cfg(target_os = "linux")]
pub(super) fn collect(_: &std::path::Path, _: Option<usize>) -> Inventory {
    use std::fs;
    let mut result = Inventory::new(Os::Linux);
    if let Ok(cards) = fs::read_dir("/sys/class/drm") {
        for entry in cards.flatten() {
            let device = entry.path().join("device");
            if let Ok(info) = fs::read_to_string(device.join("uevent")) {
                // Keep all uevents in the driver fingerprint, including render nodes.
                result.linux_driver_state.push(info);
                if entry
                    .file_name()
                    .to_string_lossy()
                    .strip_prefix("card")
                    .is_some_and(|n| n.parse::<u32>().is_ok())
                {
                    let hex = |name| {
                        fs::read_to_string(device.join(name))
                            .ok()
                            .and_then(|v| {
                                u32::from_str_radix(v.trim().trim_start_matches("0x"), 16).ok()
                            })
                            .unwrap_or(0)
                    };
                    result.adapters.push(Adapter {
                        vendor_id: hex("vendor"),
                        device_id: hex("device"),
                        subsystem_id: (hex("subsystem_device") << 16) | hex("subsystem_vendor"),
                        revision: hex("revision"),
                        description: fs::read_link(device.join("driver"))
                            .ok()
                            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
                            .unwrap_or_default(),
                        has_outputs: fs::read_dir(entry.path())
                            .into_iter()
                            .flatten()
                            .flatten()
                            .any(|e| e.path().join("status").exists()),
                        driver_version: fs::read_to_string(device.join("driver/module/version"))
                            .ok()
                            .map(|v| v.trim().to_owned()),
                        ..Adapter::default()
                    });
                }
            }
        }
    }
    for path in ["/proc/driver/nvidia/version", "/proc/sys/kernel/osrelease"] {
        if let Ok(info) = fs::read_to_string(path) {
            result.linux_driver_state.push(info);
        }
    }
    if let Ok(stamp) = fs::metadata("/etc/ld.so.cache").and_then(|m| m.modified()) {
        result.linux_driver_state.push(format!("{stamp:?}"));
    }
    for key in [
        "DRI_PRIME",
        "MESA_LOADER_DRIVER_OVERRIDE",
        "VK_DRIVER_FILES",
        "LIBGL_ALWAYS_SOFTWARE",
    ] {
        result
            .linux_driver_state
            .push(format!("{key}={:?}", std::env::var_os(key)));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn umd_version_uses_four_unsigned_words() {
        assert_eq!(umd_version(0x001b_0014_040a_0006), "27.20.1034.6");
        assert_eq!(umd_version(-1), "65535.65535.65535.65535");
    }

    #[test]
    fn fingerprint_tracks_build_and_selection_across_reenumeration() {
        let mut inv = Inventory::new(Os::Windows);
        inv.adapters = vec![
            Adapter {
                vendor_id: 0x1002,
                device_id: 0x15dd,
                ..Default::default()
            },
            Adapter::default(),
        ];
        inv.active = Some(0);
        let first = inv.fingerprint();
        inv.adapters.reverse();
        inv.active = Some(1);
        let gpu = &mut inv.adapters[1];
        gpu.luid = Some(123);
        gpu.description = "Renamed adapter".into();
        gpu.has_outputs = true;
        assert_eq!(first, inv.fingerprint());
        inv.active = Some(0);
        assert_ne!(first, inv.fingerprint());
        inv.active = Some(1);
        inv.adapters[1].driver_version = Some("27.20.1034.7".into());
        assert_ne!(first, inv.fingerprint());
    }

    #[test]
    fn ties_follow_factory_order_and_explicit_index_overrides_score() {
        let mut inv = Inventory::new(Os::Windows);
        inv.adapters = vec![
            Adapter {
                software: true,
                ..Default::default()
            },
            Adapter::default(),
            Adapter::default(),
        ];
        inv.select_d3d12(false, None);
        assert_eq!(inv.active, Some(1));
        inv.select_d3d12(false, Some(2));
        assert_eq!(inv.active, Some(2));
        inv.select_d3d12(false, Some(7));
        assert_eq!(inv.active, Some(1));
    }
}
