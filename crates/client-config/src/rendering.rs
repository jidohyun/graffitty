//! Defaults based on the active renderer, never the host CPU or OS.
use crate::config::Settings;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdapterType {
    Cpu,
    Integrated,
    Discrete,
    Virtual,
    Other,
    Headless,
}

pub fn is_software(adapter: AdapterType, name: &str) -> bool {
    match adapter {
        AdapterType::Cpu => true,
        AdapterType::Integrated | AdapterType::Discrete | AdapterType::Headless => false,
        // OpenGL does not expose a device type. Virtual adapters may also
        // advertise an explicit software renderer; virtualization alone is
        // not evidence of software rendering.
        AdapterType::Other | AdapterType::Virtual => {
            let name = name.to_ascii_lowercase();
            [
                "llvmpipe",
                "lavapipe",
                "softpipe",
                "swiftshader",
                "software rasterizer",
                "software renderer",
                "microsoft basic render driver",
                "gdi generic",
                "openswr",
            ]
            .iter()
            .any(|software| name.contains(software))
        }
    }
}

/// Fill missing preferences only. These runtime defaults are never saved to
/// client.toml, so another machine or a later hardware renderer keeps its own
/// defaults. Explicit world, profile and power-policy choices remain intact.
pub fn apply_defaults(settings: &mut Settings, software: bool) {
    if !software {
        return;
    }
    settings
        .world
        .get_or_insert_default()
        .path
        .get_or_insert_with(|| "flat-2d".into());
    settings
        .effects
        .get_or_insert_default()
        .profile
        .get_or_insert_with(|| "off".into());
    if let Some(power) = &mut settings.power {
        power.battery_world.get_or_insert_with(|| "flat-2d".into());
        power.external_world.get_or_insert_with(|| "flat-2d".into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{bindings::Platform, config};

    fn settings(source: &str) -> Settings {
        config::resolve_documents(vec![toml::from_str(source).unwrap()], Platform::Linux)
            .unwrap()
            .settings
    }

    #[test]
    fn detects_cpu_devices_and_named_software_adapters() {
        assert!(is_software(AdapterType::Cpu, "Unknown CPU renderer"));
        for name in [
            "llvmpipe (LLVM 19.1.7, 256 bits)",
            "lavapipe",
            "softpipe",
            "ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)), SwiftShader driver)",
            "Software Rasterizer",
            "Apple Software Renderer",
            "Microsoft Basic Render Driver",
            "GDI Generic",
            "OpenSWR",
        ] {
            assert!(is_software(AdapterType::Other, name), "{name}");
            assert!(is_software(AdapterType::Virtual, name), "{name}");
        }
    }

    #[test]
    fn integrated_virtual_unknown_and_headless_are_not_assumed_software() {
        for (adapter, name) in [
            (AdapterType::Integrated, "Intel(R) UHD Graphics 630"),
            (AdapterType::Integrated, "AMD Radeon Graphics"),
            (AdapterType::Integrated, "Apple M1 Max"),
            (AdapterType::Integrated, "Adreno (TM) 830"),
            (AdapterType::Other, "Adreno (TM) 830"),
            (AdapterType::Integrated, "Mali-G715"),
            (AdapterType::Discrete, "NVIDIA GeForce RTX 3060"),
            (AdapterType::Other, "Mesa Intel(R) Xe Graphics"),
            (AdapterType::Virtual, "VirGL"),
            (AdapterType::Other, "SVGA3D"),
            (AdapterType::Other, "Microsoft Basic Display Adapter"),
            (AdapterType::Other, ""),
            (AdapterType::Headless, "llvmpipe"),
        ] {
            assert!(!is_software(adapter, name), "{name}");
        }
    }

    #[test]
    fn software_defaults_apply_without_rewriting_explicit_choices() {
        let mut value = settings("");
        apply_defaults(&mut value, true);
        assert_eq!(value.world.unwrap().path.as_deref(), Some("flat-2d"));
        assert_eq!(value.effects.unwrap().profile.as_deref(), Some("off"));

        for path in ["flat-3d", ""] {
            let mut value = settings(&format!(
                "[world]\npath = {path:?}\n[effects]\nprofile = 'mild'"
            ));
            let before = value.clone();
            apply_defaults(&mut value, true);
            assert_eq!(value, before);
        }
        let mut value = settings("[effects]\nprofile = 'world'");
        apply_defaults(&mut value, true);
        assert_eq!(value.world.unwrap().path.as_deref(), Some("flat-2d"));
        assert_eq!(value.effects.unwrap().profile.as_deref(), Some("world"));
        let mut value = settings("[world]\npath = 'flat-3d'");
        apply_defaults(&mut value, true);
        assert_eq!(value.world.unwrap().path.as_deref(), Some("flat-3d"));
        assert_eq!(value.effects.unwrap().profile.as_deref(), Some("off"));
    }

    #[test]
    fn hardware_preserves_normal_defaults_and_power_policy_can_override_software() {
        let mut value = settings("");
        let before = value.clone();
        apply_defaults(&mut value, false);
        assert_eq!(value, before);
        let mut value = settings("[power]\nenabled = true\nbattery_world = 'custom-world'");
        apply_defaults(&mut value, true);
        let power = value.power.unwrap();
        assert_eq!(power.battery_world.as_deref(), Some("custom-world"));
        assert_eq!(power.external_world.as_deref(), Some("flat-2d"));
    }

    #[test]
    fn mobile_hardware_keeps_world_effects_without_an_override() {
        for (platform, gpu) in [
            (Platform::Android, "Adreno (TM) 830"),
            (Platform::Ios, "Apple A16"),
        ] {
            for adapter in [AdapterType::Integrated, AdapterType::Other] {
                let mut value = config::resolve_documents(vec![], platform)
                    .unwrap()
                    .settings;
                apply_defaults(&mut value, is_software(adapter, gpu));
                // Mobile presentation defaults to Flat 2D. The renderer policy
                // must leave its normal World Default effects untouched.
                assert!(value.world.is_none());
                assert!(value.effects.is_none());
            }
        }
    }
}
