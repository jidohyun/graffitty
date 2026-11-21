//! One registry for bundled presenters, their overrides, and user panels.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Host {
    Panel,
    /// A titleless, non-folding strip that stays in a top or bottom dock.
    Bar,
    Pane,
    Embedded,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Left,
    Right,
    Top,
    Bottom,
    None,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct Mod {
    pub entry: Option<String>,
    pub title: Option<String>,
    pub host: Option<Host>,
    pub place: Option<Side>,
    pub after: Option<String>,
    pub sides: Option<Vec<Side>>,
    pub size: Option<f64>,
    pub open: Option<bool>,
    pub enabled: Option<bool>,
    pub background_opacity: Option<f64>,
    pub background_blur: Option<bool>,
    pub background_blur_radius: Option<f64>,
    pub props: BTreeMap<String, toml::Value>,
}

pub type Registry = BTreeMap<String, Mod>;
pub const DEFAULTS: &str = include_str!("../defaults/mods.toml");

pub fn validate(mods: &Registry) -> Result<(), String> {
    for (id, spec) in mods {
        if id.is_empty()
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        {
            return Err(format!(
                "mods.{id}: IDs must contain only letters, digits, hyphens and underscores"
            ));
        }
        if spec.entry.as_ref().is_some_and(|s| s.trim().is_empty())
            || spec.title.as_ref().is_some_and(|s| s.trim().is_empty())
        {
            return Err(format!("mods.{id}: entry and title cannot be empty"));
        }
        for (field, value, min, max) in [
            ("size", spec.size, 1.0, 10000.0),
            ("background_opacity", spec.background_opacity, 0.0, 1.0),
            (
                "background_blur_radius",
                spec.background_blur_radius,
                0.0,
                64.0,
            ),
        ] {
            if value.is_some_and(|v| !v.is_finite() || !(min..=max).contains(&v)) {
                return Err(format!("mods.{id}.{field} must be between {min} and {max}"));
            }
        }
        if let Some(sides) = &spec.sides {
            if sides.contains(&Side::None)
                || sides
                    .iter()
                    .enumerate()
                    .any(|(i, side)| sides[..i].contains(side))
            {
                return Err(format!(
                    "mods.{id}.sides must contain distinct docking sides"
                ));
            }
        }
    }
    Ok(())
}

pub fn resolve(overrides: Registry) -> Result<Registry, String> {
    let mut table: toml::Table = DEFAULTS.parse().expect("bundled mod defaults");
    let builtin: Registry = toml::from_str(DEFAULTS).expect("bundled mod defaults");
    // Serialize only configured values, so omitted fields inherit defaults.
    for (id, spec) in overrides {
        let mut value = toml::Value::try_from(spec).map_err(|e| e.to_string())?;
        let fields = value.as_table_mut().unwrap();
        fields.retain(|_, value| !matches!(value, toml::Value::Table(t) if t.is_empty()));
        let existing = table
            .entry(id)
            .or_insert_with(|| toml::Value::Table(toml::Table::new()));
        crate::config::merge(existing.as_table_mut().unwrap(), fields.clone());
    }
    let mut mods = Registry::deserialize(toml::Value::Table(table)).map_err(|e| e.to_string())?;
    validate(&mods)?;
    for (id, spec) in &mut mods {
        if spec.entry.is_none() || spec.host.is_none() {
            return Err(format!("mods.{id}: new mods require entry and host"));
        }
        if let Some(original) = builtin.get(id) {
            if spec.host != original.host {
                return Err(format!("mods.{id}: a built-in mod must retain its host"));
            }
        } else if spec.host == Some(Host::Embedded) {
            return Err(format!(
                "mods.{id}: embedded presenters require an existing native host; use panel, bar or pane"
            ));
        }
        spec.title.get_or_insert_with(|| id.clone());
        spec.enabled.get_or_insert(true);
        spec.open.get_or_insert(false);
        spec.background_opacity.get_or_insert(1.0);
        spec.background_blur.get_or_insert(true);
        spec.background_blur_radius.get_or_insert(12.0);
        if matches!(spec.host, Some(Host::Panel | Host::Bar)) {
            let bar = spec.host == Some(Host::Bar);
            if bar {
                spec.place.get_or_insert(Side::Bottom);
                spec.sides.get_or_insert(vec![Side::Top, Side::Bottom]);
                spec.size.get_or_insert(32.0);
            }
            let place = *spec.place.get_or_insert(Side::None);
            let sides =
                spec.sides
                    .get_or_insert(vec![Side::Left, Side::Right, Side::Top, Side::Bottom]);
            if place != Side::None && !sides.contains(&place) {
                return Err(format!("mods.{id}.place must be included in sides"));
            }
            if bar && (!matches!(place, Side::Top | Side::Bottom)
                || sides.iter().any(|side| !matches!(side, Side::Top | Side::Bottom))) {
                return Err(format!("mods.{id}: bars require top/bottom placement and sides"));
            }
        } else if spec.place.is_some()
            || spec.sides.is_some()
            || spec.size.is_some()
            || spec.after.is_some()
            || spec.open == Some(true)
        {
            return Err(format!(
                "mods.{id}: placement, size, after and open apply only to panels and bars"
            ));
        }
    }
    order(&mods)?;
    Ok(mods)
}

/// Deterministic initial ordering, with dependency validation before any UI opens.
pub fn order(mods: &Registry) -> Result<Vec<String>, String> {
    fn visit(
        id: &str,
        mods: &Registry,
        visiting: &mut BTreeSet<String>,
        result: &mut Vec<String>,
    ) -> Result<(), String> {
        if result.iter().any(|name| name == id) {
            return Ok(());
        }
        if !visiting.insert(id.into()) {
            return Err(format!("mods.{id}.after forms a cycle"));
        }
        let spec = &mods[id];
        if let Some(after) = &spec.after {
            let Some(target) = mods.get(after) else {
                return Err(format!("mods.{id}.after: unknown mod {after}"));
            };
            if !matches!(target.host, Some(Host::Panel | Host::Bar)) || target.place != spec.place {
                return Err(format!(
                    "mods.{id}.after must name a panel with the same default place"
                ));
            }
            visit(after, mods, visiting, result)?;
        }
        visiting.remove(id);
        result.push(id.into());
        Ok(())
    }
    let mut result = Vec::new();
    for id in mods.keys() {
        visit(id, mods, &mut BTreeSet::new(), &mut result)?;
    }
    Ok(result)
}

pub fn persistence_key(id: &str) -> String {
    match id {
        "agents" | "sessions" => id.into(),
        "pane-status" => "pane_status".into(),
        "resource-monitor" => "resource_monitor".into(),
        "status-line" => "status_line".into(),
        _ => format!("panel:{id}"),
    }
}
