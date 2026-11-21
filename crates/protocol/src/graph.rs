//! Graph wire types and schema rules. No transport, server, engine, or UI dependencies.
//! Application metadata stays opaque; fields that determine
//! routing and client state are decoded into Rust types before a frontend sees them.
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashSet};
pub type Result<T> = std::result::Result<T, String>;
fn string<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}

pub fn normalize_icon(value: &Value) -> Result<Value> {
    let owned;
    let value = if value.is_string() {
        owned = json!({"text":value});
        &owned
    } else {
        value
    };
    if !value.is_object() {
        return Err("icon must be text or an object".into());
    }
    if let Some(svg) = value.get("svg") {
        let svg = svg
            .as_str()
            .filter(|s| s.chars().count() <= 16384 && s.contains("<svg"))
            .ok_or("icon.svg must be inline SVG of at most 16384 characters")?;
        return Ok(json!({"svg":svg}));
    }
    let text = value
        .get("text")
        .map(|v| {
            v.as_str()
                .filter(|s| s.chars().count() <= 32)
                .ok_or("icon.text must be at most 32 characters")
        })
        .transpose()?
        .unwrap_or("");
    let font = value
        .get("font")
        .map(|v| {
            v.as_str()
                .filter(|s| s.chars().count() <= 128)
                .ok_or("icon.font must be a font family of at most 128 characters")
        })
        .transpose()?
        .unwrap_or("");
    Ok(json!({"text":text,"font":font}))
}

pub fn normalize_manifest(value: &Value) -> Result<Value> {
    if !value.is_object() {
        return Err("Manifest must be an object".into());
    }
    if value
        .get("name")
        .is_some_and(|v| v.as_str().is_none_or(|s| s.len() > 128))
    {
        return Err("Invalid manifest name".into());
    }
    let mut result = value.clone();
    if result.get("name").is_none() {
        result["name"] = json!("");
    }
    if let Some(icon) = result.get("icon") {
        result["icon"] = normalize_icon(icon)?;
    }
    for direction in ["inputs", "outputs"] {
        let items = result[direction]
            .as_array_mut()
            .ok_or("Expected ports array")?;
        if items.len() > 32 {
            return Err("At most 32 ports per direction".into());
        }
        let mut seen = HashSet::new();
        for p in items {
            if !p.is_object() {
                return Err("Each port must be an object".into());
            }
            let id = string(p, "id");
            if id.is_empty()
                || id.len() > 64
                || !id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
                || !seen.insert(id.to_owned())
            {
                return Err("Invalid or duplicate port ID".into());
            }
            if p.get("name")
                .is_some_and(|v| v.as_str().is_none_or(|s| s.len() > 128))
            {
                return Err("Invalid port name".into());
            }
            if p.get("name").is_none() {
                p["name"] = json!("");
            }
            if let Some(icon) = p.get("icon") {
                p["icon"] = normalize_icon(icon)?;
            }
            if let Some(color) = p.get("color") {
                let c = color.as_str().ok_or("Invalid port color")?;
                if c.len() != 7
                    || !c.starts_with('#')
                    || !c[1..].bytes().all(|b| b.is_ascii_hexdigit())
                {
                    return Err("Invalid port color".into());
                }
                p["color"] = json!(c.to_ascii_lowercase());
            } else {
                p["color"] = json!(if direction == "inputs" {
                    "#8ecaff"
                } else {
                    "#89ddbd"
                });
            }
            if direction == "outputs" {
                if p.get("mode").is_none() {
                    p["mode"] = json!("send");
                }
                if !["send", "read", "turn_completed"].contains(&string(p, "mode")) {
                    return Err("Invalid output mode".into());
                }
            }
            if p.get("line_style").is_some()
                && (direction != "outputs"
                    || !["solid", "dashed"].contains(&string(p, "line_style")))
            {
                return Err("Output line_style must be solid or dashed".into());
            }
        }
    }
    Ok(result)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeKind {
    Agent,
    Custom,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PortMode {
    Read,
    Send,
    TurnCompleted,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LineStyle {
    Solid,
    Dashed,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Icon {
    Svg {
        svg: String,
    },
    Text {
        text: String,
        #[serde(default)]
        font: String,
    },
}
impl<'de> Deserialize<'de> for Icon {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let value = normalize_icon(&Value::deserialize(d)?).map_err(serde::de::Error::custom)?;
        Ok(if let Some(svg) = value.get("svg") {
            Self::Svg {
                svg: svg.as_str().unwrap().into(),
            }
        } else {
            Self::Text {
                text: string(&value, "text").into(),
                font: string(&value, "font").into(),
            }
        })
    }
}
impl From<String> for Icon {
    fn from(text: String) -> Self {
        Self::Text {
            text,
            font: String::new(),
        }
    }
}
impl From<&str> for Icon {
    fn from(text: &str) -> Self {
        text.to_owned().into()
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Port {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub color: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<PortMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_style: Option<LineStyle>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub name: String,
    pub inputs: Vec<Port>,
    pub outputs: Vec<Port>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl Manifest {
    pub fn decode(value: Value) -> Result<Self> {
        serde_json::from_value(normalize_manifest(&value)?).map_err(|e| e.to_string())
    }
}
fn manifest_field<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<Manifest>, D::Error> {
    let value = Option::<Value>::deserialize(d)?;
    value
        .map(Manifest::decode)
        .transpose()
        .map_err(serde::de::Error::custom)
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Node {
    #[serde(default)]
    pub node: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<NodeKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(
        default,
        deserialize_with = "manifest_field",
        skip_serializing_if = "Option::is_none"
    )]
    pub manifest: Option<Manifest>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl Node {
    pub fn builtin(&self) -> bool {
        matches!(self.provider.as_deref(), Some("claude" | "codex" | "opencode" | "pi"))
    }
    pub fn ports(&self, output: bool) -> Vec<Port> {
        if let Some(manifest) = &self.manifest {
            return if output {
                &manifest.outputs
            } else {
                &manifest.inputs
            }
            .clone();
        }
        builtin_ports(self.provider.as_deref().unwrap_or(""), output)
    }
}
pub fn builtin_ports(provider: &str, output: bool) -> Vec<Port> {
    if !matches!(provider, "claude" | "codex" | "opencode" | "pi") {
        return vec![];
    }
    let ports = if output {
        json!([
            {"id":"read","mode":"read","name":"Read","color":"#8ecaff"},
            {"id":"send","mode":"send","name":"Send","color":"#89ddbd"},
            {"id":"turn_completed","mode":"turn_completed","name":"Turn completed","color":"#7bd88f"},
            {"id":"waiting","mode":"send","name":"Waiting","color":"#ffd47a","line_style":"solid"},
            {"id":"error","mode":"send","name":"Error","color":"#ff6b6b","line_style":"solid"}
        ])
    } else {
        json!([{"id":"in","name":"Receive","color":"#8ecaff"}])
    };
    serde_json::from_value(ports).expect("static port schema")
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Edge {
    pub from: String,
    pub to: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub from_port: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub to_port: String,
    #[serde(default)]
    pub read: bool,
    #[serde(default)]
    pub send: bool,
    #[serde(default)]
    pub turn_completed: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub contains: String,
    #[serde(default)]
    pub outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
pub fn socket(node: &str, port: &str) -> String {
    if port.is_empty() {
        node.into()
    } else {
        format!("{node}/{port}")
    }
}
impl Edge {
    pub fn key(&self) -> String {
        format!(
            "{}>{}",
            socket(&self.from, &self.from_port),
            socket(&self.to, &self.to_port)
        )
    }
}
#[derive(Clone, Debug, Deserialize)]
pub struct Connect {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub from_port: String,
    #[serde(default)]
    pub to_port: String,
    #[serde(default)]
    pub read: bool,
    #[serde(default)]
    pub send: bool,
    #[serde(default)]
    pub turn_completed: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub contains: Option<String>,
    #[serde(default)]
    pub outcome: Option<String>,
}
/// Canonical connection used both by the server and optimistic client previews.
/// Only the server assigns revisions and authorizes delivery.
pub fn connection(
    params: &Value,
    source: &Node,
    target: &Node,
    previous: impl FnOnce(&str) -> Option<Edge>,
) -> Result<Edge> {
    let p: Connect = serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
    if p.from == p.to {
        return Err("Choose two different live nodes in this workspace".into());
    }
    if source.builtin() && p.from_port.is_empty() && p.send && (p.read || p.turn_completed) {
        return Err("Use separate Read, Send, and Turn completed connections".into());
    }
    let requested = if p.from_port.is_empty() && source.builtin() {
        if p.turn_completed {
            "turn_completed"
        } else if p.send {
            "send"
        } else {
            "read"
        }
    } else {
        &p.from_port
    };
    let resolve = |node: &Node, output, id: &str| -> Result<Port> {
        let ports = node.ports(output);
        if id.is_empty() && ports.len() == 1 {
            return Ok(ports[0].clone());
        }
        ports
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| "Choose an advertised port".into())
    };
    let from = resolve(source, true, requested)?;
    let to = resolve(target, false, &p.to_port)?;
    let mode = from.mode.unwrap_or(PortMode::Send);
    let contains = p.contains.unwrap_or_default();
    if contains.chars().count() > 200 {
        return Err("Condition is at most 200 characters".into());
    }
    let outcome = p.outcome.unwrap_or_default();
    // Outcomes are node-defined strings. UI presets must not restrict the wire contract.
    let mut edge = Edge {
        from: p.from,
        to: p.to,
        from_port: from.id,
        to_port: to.id,
        read: mode != PortMode::Send,
        send: mode == PortMode::Send,
        turn_completed: mode == PortMode::TurnCompleted,
        muted: p.muted,
        contains,
        outcome,
        ..Default::default()
    };
    let previous = previous(&edge.key());
    let deadline = if let Some(value) = params.get("stop_at") {
        value
            .as_f64()
            .filter(|v| v.is_finite() && *v >= 0.)
            .ok_or("stop_at must be a non-negative finite Unix timestamp, or 0 for no stop time")?
    } else {
        previous.as_ref().and_then(|e| e.stop_at).unwrap_or(0.)
    };
    if deadline > 0. {
        edge.stop_at = Some(deadline);
    }
    Ok(edge)
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Delivery {
    pub event_id: String,
    pub source: String,
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_port: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_port: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JournalRow {
    #[serde(flatten)]
    pub delivery: Delivery,
    pub edge: String,
    pub status: String,
    pub pending: bool,
    pub queued_at: f64,
    pub updated_at: f64,
    #[serde(default)]
    pub transitions: Vec<Transition>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Transition {
    pub at: f64,
    pub status: String,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Counts {
    pub total: u64,
    pub pending: u64,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Journal {
    pub events: Vec<JournalRow>,
    pub by_edge: BTreeMap<String, Counts>,
    pub pending: u64,
    pub omitted: u64,
    pub history_limit: u64,
    pub transition_limit: u64,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RunUsage {
    pub count: u64,
    pub limit: u64,
    pub available: bool,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
    pub queues: BTreeMap<String, Vec<Delivery>>,
    pub receipts: Vec<Delivery>,
    pub journal: Journal,
    pub runs: BTreeMap<String, RunUsage>,
    pub limits: BTreeMap<String, u64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl Snapshot {
    pub fn decode(value: Value) -> Result<Self> {
        let result: Self =
            serde_json::from_value(value).map_err(|e| format!("Invalid graph snapshot: {e}"))?;
        let mut nodes = HashSet::new();
        for node in &result.nodes {
            if node.node.is_empty() || !nodes.insert(&node.node) {
                return Err("Missing or duplicate graph node".into());
            }
        }
        let mut edges = HashSet::new();
        for edge in &result.edges {
            if !edges.insert(edge.key()) || edge.stop_at.is_some_and(|t| !t.is_finite() || t < 0.) {
                return Err("Invalid or duplicate graph edge".into());
            }
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schema_normalizes_icons_and_rejects_invalid_declarations() {
        let base = json!({"inputs":[{"id":"in"}],"outputs":[{"id":"out","icon":"✓","color":"#AB12CD","line_style":"solid"}],"icon":{"text":"⚖","font":"Symbols Nerd Font Mono"}});
        let manifest = Manifest::decode(base.clone()).unwrap();
        assert_eq!(manifest.outputs[0].color, "#ab12cd");
        assert_eq!(manifest.outputs[0].mode, Some(PortMode::Send));
        assert_eq!(
            manifest.outputs[0].icon,
            Some(Icon::Text {
                text: "✓".into(),
                font: String::new()
            })
        );
        for invalid in [
            json!({"svg":"x".repeat(17000)}),
            json!({"text":123}),
            json!({"font":false}),
        ] {
            let mut value = base.clone();
            value["icon"] = invalid;
            assert!(Manifest::decode(value).is_err());
        }
        for invalid in [json!("dotted"), json!(false)] {
            let mut value = base.clone();
            value["outputs"][0]["line_style"] = invalid;
            assert!(Manifest::decode(value).is_err());
        }
    }
    #[test]
    fn previews_and_server_connections_share_modes_conditions_and_deadlines() {
        let source: Node = serde_json::from_value(json!({"provider":"claude"})).unwrap();
        let target: Node = serde_json::from_value(json!({"provider":"codex"})).unwrap();
        let params = json!({"from":"%1","to":"%2","send":true,"outcome":"custom-success"});
        let mut original = connection(&params, &source, &target, |_| None).unwrap();
        assert!(original.send && !original.read);
        assert_eq!(original.from_port, "send");
        original.stop_at = Some(123.);
        original.revision = Some(42);
        let preview = connection(&params, &source, &target, |_| Some(original.clone())).unwrap();
        assert_eq!(preview.stop_at, Some(123.));
        assert_eq!(preview.revision, None);
        for (key, value) in [
            ("send", json!("true")),
            ("read", json!(true)),
            ("stop_at", Value::Null),
            ("stop_at", json!(-1)),
            ("contains", json!({})),
            ("contains", json!("x".repeat(201))),
            ("from_port", json!("missing")),
        ] {
            let mut invalid = params.clone();
            invalid[key] = value;
            assert!(
                connection(&invalid, &source, &target, |_| None).is_err(),
                "{invalid}"
            );
        }
    }
}
