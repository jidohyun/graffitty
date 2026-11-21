use crate::Result;
pub use graffitty_protocol::graph::{Icon, LineStyle, PortMode};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// A declared input socket. Application metadata survives decode/encode.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InputPort {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl InputPort {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: None,
            color: None,
            icon: None,
            extra: Map::new(),
        }
    }
    pub fn name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }
    pub fn color(mut self, color: impl Into<String>) -> Self {
        self.color = Some(color.into());
        self
    }
    pub fn icon(mut self, icon: impl Into<Icon>) -> Self {
        self.icon = Some(icon.into());
        self
    }
}
impl From<&str> for InputPort {
    fn from(id: &str) -> Self {
        Self::new(id)
    }
}
impl From<String> for InputPort {
    fn from(id: String) -> Self {
        Self::new(id)
    }
}
fn send_mode() -> PortMode {
    PortMode::Send
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputPort {
    #[serde(flatten)]
    pub port: InputPort,
    #[serde(default = "send_mode")]
    pub mode: PortMode,
    /// None uses the host's mode-specific style. Dotted is reserved for inactive wires.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_style: Option<LineStyle>,
}
impl OutputPort {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            port: InputPort::new(id),
            mode: PortMode::Send,
            line_style: None,
        }
    }
    pub fn name(mut self, name: impl Into<String>) -> Self {
        self.port.name = Some(name.into());
        self
    }
    pub fn color(mut self, color: impl Into<String>) -> Self {
        self.port.color = Some(color.into());
        self
    }
    pub fn icon(mut self, icon: impl Into<Icon>) -> Self {
        self.port.icon = Some(icon.into());
        self
    }
    pub fn mode(mut self, mode: PortMode) -> Self {
        self.mode = mode;
        self
    }
    pub fn line_style(mut self, style: LineStyle) -> Self {
        self.line_style = Some(style);
        self
    }
}
// String shorthand is for automatic handlers; configured ports keep their chosen style.
impl From<&str> for OutputPort {
    fn from(id: &str) -> Self {
        Self::new(id).line_style(LineStyle::Solid)
    }
}
impl From<String> for OutputPort {
    fn from(id: String) -> Self {
        Self::new(id).line_style(LineStyle::Solid)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    pub inputs: Vec<InputPort>,
    pub outputs: Vec<OutputPort>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl Manifest {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            icon: None,
            inputs: vec![],
            outputs: vec![],
            extra: Map::new(),
        }
    }
    pub fn validate(&self) -> Result<()> {
        // Use the host's schema, including UTF-8 byte bounds, icon limits and colors.
        graffitty_protocol::graph::normalize_manifest(&serde_json::to_value(self)?)?;
        Ok(())
    }
}
pub(crate) fn validate_port(id: &str) -> Result<()> {
    if id.is_empty()
        || id.len() > 64
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
    {
        return Err("Port IDs must be 1–64 ASCII letters, digits, underscores or hyphens".into());
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionReference {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint: Option<Checkpoint>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Checkpoint {
    #[serde(deserialize_with = "integer_offset")]
    pub byte_offset: u64,
}
fn integer_offset<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<u64, D::Error> {
    let value = Value::deserialize(deserializer)?;
    // Godot's JSON bridge represents integers as doubles. Accept only exact,
    // nonnegative safe integers; never round a transcript checkpoint.
    value
        .as_u64()
        .or_else(|| {
            value
                .as_f64()
                .filter(|n| {
                    n.is_finite() && *n >= 0.0 && *n <= 9_007_199_254_740_991.0 && n.fract() == 0.0
                })
                .map(|n| n as u64)
        })
        .ok_or_else(|| serde::de::Error::custom("Expected a nonnegative integer checkpoint"))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub event_id: String,
    pub run_id: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub source: String,
    pub target: String,
    pub source_port: String,
    pub target_port: String,
    pub text: String,
    #[serde(default)]
    pub payload: Value,
    #[serde(default)]
    pub sessions: Vec<SessionReference>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// A patch forwarded from the input event. Absent fields retain their original
/// values, including session references and the host-owned run/provenance.
#[derive(Clone, Debug)]
pub struct Output {
    pub port: String,
    pub content: Map<String, Value>,
}
impl Output {
    pub fn new(port: impl Into<String>) -> Self {
        Self {
            port: port.into(),
            content: Map::new(),
        }
    }
    pub fn text(port: impl Into<String>, text: impl Into<String>) -> Self {
        let mut output = Self::new(port);
        output.content.insert("text".into(), json!(text.into()));
        output
    }
    pub fn with_payload(mut self, payload: Value) -> Self {
        self.content.insert("payload".into(), payload);
        self
    }
    pub fn with_content(mut self, content: Vec<Map<String, Value>>) -> Self {
        self.content.insert("content".into(), json!(content));
        self
    }
    pub fn with_renderings(mut self, renderings: Map<String, Value>) -> Self {
        self.content.insert("renderings".into(), json!(renderings));
        self
    }
    pub fn validate(&self) -> Result<()> {
        validate_port(&self.port)?;
        if self
            .content
            .keys()
            .any(|k| !["text", "payload", "content", "renderings"].contains(&k.as_str()))
        {
            return Err("Only text, payload, content and renderings may be overridden".into());
        }
        if self.content.get("text").is_some_and(|v| !v.is_string()) {
            return Err("Output text must be a string".into());
        }
        if self.content.get("content").is_some_and(|v| {
            v.as_array()
                .is_none_or(|items| items.iter().any(|item| !item.is_object()))
        }) {
            return Err("Output content must be an array of objects".into());
        }
        if self
            .content
            .get("renderings")
            .is_some_and(|v| !v.is_object())
        {
            return Err("Output renderings must be an object".into());
        }
        Ok(())
    }
}
