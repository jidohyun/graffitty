//! Hardware rules are evaluated before selecting the supervised renderer.
use super::inventory::{Inventory, Os};
use std::cmp::Ordering;

#[derive(Clone, Copy)]
#[allow(dead_code)] // Supported rule operators, even if the current table only uses equality.
enum Version {
    Equal(&'static [u32]),
    Less(&'static [u32]),
    LessEqual(&'static [u32]),
    Greater(&'static [u32]),
    GreaterEqual(&'static [u32]),
    Between(&'static [u32], &'static [u32]),
}

impl Version {
    fn matches(self, version: &str) -> bool {
        let Some(parts) = version
            .split('.')
            .map(|s| {
                if s.bytes().all(|b| b.is_ascii_digit()) {
                    s.parse::<u32>().ok()
                } else {
                    None
                }
            })
            .collect::<Option<Vec<_>>>()
        else {
            return false;
        };
        // Chromium numeric style compares through the last component specified
        // in the rule. Require that the observed build supplies those components.
        let compare = |reference: &[u32]| parts.get(..reference.len()).map(|v| v.cmp(reference));
        match self {
            Self::Equal(v) => compare(v) == Some(Ordering::Equal),
            Self::Less(v) => compare(v) == Some(Ordering::Less),
            Self::LessEqual(v) => compare(v).is_some_and(Ordering::is_le),
            Self::Greater(v) => compare(v) == Some(Ordering::Greater),
            Self::GreaterEqual(v) => compare(v).is_some_and(Ordering::is_ge),
            Self::Between(lo, hi) => {
                compare(lo).is_some_and(Ordering::is_ge) && compare(hi).is_some_and(Ordering::is_le)
            }
        }
    }
}

#[derive(Clone, Copy)]
#[allow(dead_code)] // Categories supported by the control list.
enum Category {
    Primary,
    Active,
    Any,
}

#[derive(Clone, Copy)]
struct Conditions {
    os: Os,
    vendor_id: u32,
    device_ids: &'static [u32],
    driver_version: Option<Version>,
    multi_gpu_category: Category,
}

impl Conditions {
    fn matches(self, inventory: &Inventory) -> bool {
        self.os == inventory.os
            && inventory.adapters.iter().enumerate().any(|(i, gpu)| {
                let candidate = match self.multi_gpu_category {
                    Category::Primary => inventory.primary == Some(i),
                    Category::Active => inventory.active == Some(i),
                    Category::Any => true,
                };
                candidate
                    && !gpu.software
                    && self.vendor_id == gpu.vendor_id
                    && (self.device_ids.is_empty() || self.device_ids.contains(&gpu.device_id))
                    && self.driver_version.is_none_or(|rule| {
                        gpu.driver_version
                            .as_deref()
                            .is_some_and(|v| rule.matches(v))
                    })
            })
    }
}

struct Rule {
    id: u32,
    description: &'static str,
    conditions: Conditions,
    exceptions: &'static [Conditions],
    disabled_modes: &'static [&'static str],
}

impl Rule {
    fn matches(&self, inventory: &Inventory) -> bool {
        self.conditions.matches(inventory) && !self.exceptions.iter().any(|c| c.matches(inventory))
    }
}

// PCI IDs identify APU families, not the enabled CU count. These families
// include eight-CU SKUs and also share IDs with other SKUs. Later eight-CU
// products are branded "AMD Radeon Graphics". The exact driver build matters.
// https://pci-ids.ucw.cz/read/PC/1002
// https://gitlab.freedesktop.org/mesa/drm/-/blob/main/data/amdgpu.ids
// https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/ryzen-5000-series/amd-ryzen-7-5825u.html
const VEGA_FAMILIES: &[u32] = &[
    0x15dd, // Raven Ridge
    0x15d8, // Picasso
    0x1636, // Renoir
    0x164c, // Lucienne
    0x1638, // Cezanne
    0x15e7, // Barcelo
];

const RULES: &[Rule] = &[Rule {
    id: 1,
    description: "D3D12 first-buffer device removal on AMD Vega APU driver 27.20.1034.6",
    conditions: Conditions {
        os: Os::Windows,
        vendor_id: 0x1002,
        device_ids: VEGA_FAMILIES,
        driver_version: Some(Version::Equal(&[27, 20, 1034, 6])),
        multi_gpu_category: Category::Active,
    },
    exceptions: &[],
    disabled_modes: &["d3d12"],
}];

pub(super) fn matched_rule_ids(inventory: &Inventory) -> Vec<u32> {
    RULES
        .iter()
        .filter(|r| r.matches(inventory))
        .map(|r| r.id)
        .collect()
}

pub(super) fn disabled_modes(inventory: &Inventory) -> Vec<&'static str> {
    let mut modes = Vec::new();
    for r in RULES.iter().filter(|r| r.matches(inventory)) {
        for &mode in r.disabled_modes {
            if !modes.contains(&mode) {
                modes.push(mode);
            }
        }
    }
    modes
}

#[cfg(test)]
mod tests {
    use super::super::inventory::Adapter;
    use super::*;

    fn hybrid() -> Inventory {
        let mut inv = Inventory::new(Os::Windows);
        inv.adapters = vec![
            Adapter {
                vendor_id: 0x10de,
                dedicated_video_memory: 1024,
                ..Default::default()
            },
            Adapter {
                vendor_id: 0x1002,
                device_id: 0x15dd,
                description: "OEM display".into(),
                has_outputs: true,
                driver_version: Some("27.20.1034.6".into()),
                ..Default::default()
            },
        ];
        inv.primary = Some(1);
        inv
    }

    #[test]
    fn hybrid_rule_follows_selected_adapter() {
        let mut inv = hybrid();
        inv.select_d3d12(false, None);
        assert!(disabled_modes(&inv).is_empty());
        inv.select_d3d12(true, None);
        assert_eq!(disabled_modes(&inv), ["d3d12"]);
        assert_eq!(matched_rule_ids(&inv), [1]);
        for &id in VEGA_FAMILIES {
            inv.adapters[1].device_id = id;
            assert_eq!(matched_rule_ids(&inv), [1]);
        }
        inv.adapters[1].driver_version = None;
        assert!(disabled_modes(&inv).is_empty());
    }

    #[test]
    fn exclusions_and_unknown_selection() {
        let mut inv = hybrid();
        assert!(disabled_modes(&inv).is_empty());
        inv.active = Some(1);
        inv.adapters[1].software = true;
        assert!(disabled_modes(&inv).is_empty());
        inv.adapters[1].software = false;
        inv.os = Os::Linux;
        assert!(disabled_modes(&inv).is_empty());
        inv.os = Os::Windows;
        inv.adapters[1].device_id = 0xffff;
        assert!(disabled_modes(&inv).is_empty());
        inv.adapters[1].device_id = 0x1636;
        inv.adapters[1].driver_version = Some("27.20.1034.7".into());
        assert!(disabled_modes(&inv).is_empty());
    }

    #[test]
    fn primary_any_and_exceptions() {
        let mut inv = hybrid();
        inv.select_d3d12(false, None);
        let condition = RULES[0].conditions;
        for category in [Category::Primary, Category::Any] {
            assert!(
                Conditions {
                    multi_gpu_category: category,
                    ..condition
                }
                .matches(&inv)
            );
        }
        inv.select_d3d12(true, None);
        const EXCEPTION: Conditions = Conditions {
            vendor_id: 0x10de,
            device_ids: &[],
            driver_version: None,
            multi_gpu_category: Category::Any,
            os: Os::Windows,
        };
        let rule = Rule {
            exceptions: &[EXCEPTION],
            ..RULES[0]
        };
        assert!(!rule.description.is_empty());
        assert!(!rule.matches(&inv));
    }

    #[test]
    fn numeric_version_operators() {
        use Version::*;
        assert!(Equal(&[27, 20, 1034, 6]).matches("27.20.01034.6"));
        assert!(Less(&[10]).matches("9.123"));
        assert!(LessEqual(&[10, 2]).matches("10.2.33"));
        assert!(Greater(&[10, 2]).matches("10.11"));
        assert!(GreaterEqual(&[10, 2]).matches("10.2"));
        let between = Between(&[10, 2], &[10, 11]);
        for v in ["10.2", "10.9", "10.11"] {
            assert!(between.matches(v));
        }
        for v in ["10.12", "", "10..2", "10.2-beta", "10.+2"] {
            assert!(!between.matches(v));
        }
        assert!(!Equal(&[27, 20, 1034, 6]).matches("27.20.1034"));
    }
}
