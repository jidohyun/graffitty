//! Godot values/signals only. Graph decoding, state and schema live in shared Rust.
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_client_core::graph_state::GraphState;
use serde_json::{Value, json};

pub(crate) fn from_variant(value: &Variant) -> Result<Value, String> {
    Ok(match value.get_type() {
        VariantType::NIL => Value::Null,
        VariantType::BOOL => json!(value.to::<bool>()),
        VariantType::INT => json!(value.to::<i64>()),
        VariantType::FLOAT => {
            let n = value.to::<f64>();
            if !n.is_finite() {
                return Err("Expected a finite number".into());
            }
            // Godot JSON parsing represents numbers as floats. Never round
            // fractions or accept an integer outside exact float range.
            if n.fract() == 0. && n.abs() <= 9_007_199_254_740_991. {
                json!(n as i64)
            } else {
                json!(n)
            }
        }
        VariantType::STRING => json!(value.to::<GString>().to_string()),
        VariantType::STRING_NAME => json!(value.to::<StringName>().to_string()),
        VariantType::ARRAY => Value::Array(
            value
                .to::<godot::builtin::AnyArray>()
                .iter_shared()
                .map(|v| from_variant(&v))
                .collect::<Result<_, _>>()?,
        ),
        VariantType::DICTIONARY => {
            let mut object = serde_json::Map::new();
            for (key, value) in value.to::<godot::builtin::AnyDictionary>().iter_shared() {
                // GDScript dot assignment creates StringName keys, including
                // Chromium input fields added after the initial dictionary.
                let key = match key.get_type() {
                    VariantType::STRING => key.to::<GString>().to_string(),
                    VariantType::STRING_NAME => key.to::<StringName>().to_string(),
                    _ => return Err("Expected string dictionary key".into()),
                };
                object.insert(key, from_variant(&value)?);
            }
            Value::Object(object)
        }
        _ => return Err("Expected a JSON-compatible value".into()),
    })
}
pub(crate) fn to_variant(value: &Value) -> Variant {
    match value {
        Value::Null => Variant::nil(),
        Value::Bool(v) => v.to_variant(),
        Value::Number(n) => {
            if let Some(v) = n.as_i64() {
                v.to_variant()
            } else if let Some(v) = n.as_u64() {
                // Server IDs/counters are restricted to signed 64-bit range.
                // An opaque future u64 still stays exact as decimal text.
                v.to_string().to_variant()
            } else {
                n.as_f64().unwrap().to_variant()
            }
        }
        Value::String(s) => s.to_variant(),
        Value::Array(items) => items
            .iter()
            .map(to_variant)
            .collect::<VarArray>()
            .to_variant(),
        Value::Object(object) => {
            let mut d = VarDictionary::new();
            for (key, value) in object {
                d.set(key.as_str(), &to_variant(value));
            }
            d.to_variant()
        }
    }
}
fn reply(result: Result<Value, String>) -> VarDictionary {
    to_variant(&result.unwrap_or_else(|error| json!({"error":error}))).to()
}

/// Cached owner snapshots are shared across messages. Freeze every container,
/// including nested arrays, so presentation code must explicitly copy to edit.
pub(crate) fn to_read_only_variant(value: &Value) -> Variant {
    match value {
        Value::Array(items) => items.iter().map(to_read_only_variant)
            .collect::<VarArray>().into_read_only().to_variant(),
        Value::Object(object) => {
            let mut dictionary = VarDictionary::new();
            for (key, value) in object {
                dictionary.set(key.as_str(), &to_read_only_variant(value));
            }
            dictionary.into_read_only().to_variant()
        }
        _ => to_variant(value),
    }
}
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct GraphClientCore {
    base: Base<RefCounted>,
    state: GraphState,
}
#[godot_api]
impl IRefCounted for GraphClientCore {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            state: GraphState::default(),
        }
    }
}
#[godot_api]
impl GraphClientCore {
    #[func]
    fn receive(&mut self, owner: i64, snapshot: VarDictionary) -> VarDictionary {
        reply((|| {
            let changes = self
                .state
                .receive(owner as u64, from_variant(&snapshot.to_variant())?)?;
            if !changes.changed {
                return Ok(json!({"changes": changes, "view": null, "snapshot": null}));
            }
            Ok(
                json!({"changes":changes,"view":self.state.view(),"snapshot":self.state.snapshots.get(&(owner as u64))}),
            )
        })())
    }
    #[func]
    fn view(&self) -> VarDictionary {
        to_variant(&self.state.view()).to()
    }
    #[func]
    fn preview_connect(&mut self, owner: i64, params: VarDictionary) -> VarDictionary {
        reply((|| {
            let edge = self
                .state
                .preview_connect(owner as u64, &from_variant(&params.to_variant())?)?;
            Ok(json!({"result":edge}))
        })())
    }
    #[func]
    fn rollback(&mut self, owner: i64) -> VarDictionary {
        self.state.rollback(owner as u64);
        self.view()
    }
    #[func]
    fn preview_disconnect(
        &mut self,
        owner: i64,
        source: GString,
        target: GString,
        from_port: GString,
        to_port: GString,
    ) -> VarDictionary {
        self.state.preview_disconnect(
            owner as u64,
            &source.to_string(),
            &target.to_string(),
            &from_port.to_string(),
            &to_port.to_string(),
        );
        self.view()
    }
    #[func]
    fn import_journal(&mut self, owner: i64, snapshot: VarDictionary) -> VarDictionary {
        reply((|| {
            let value = from_variant(&snapshot.to_variant())?;
            let snapshot = if snapshot.is_empty() {
                None
            } else {
                Some(serde_json::from_value(value).map_err(|e| e.to_string())?)
            };
            let changed = self.state.journal.receive(owner as u64, snapshot);
            Ok(json!({"changed":changed,"entries":self.state.journal.entries}))
        })())
    }
    #[func]
    fn journal_snapshot(&self, edge: GString) -> VarDictionary {
        to_variant(&serde_json::to_value(self.state.journal.snapshot(&edge.to_string())).unwrap())
            .to()
    }
    #[func]
    fn validate_manifest(&self, value: Variant) -> VarDictionary {
        reply(
            from_variant(&value)
                .and_then(|value| graffitty_protocol::graph::normalize_manifest(&value))
                .map(|manifest| json!({"manifest":manifest})),
        )
    }
    #[func]
    fn validate_icon(&self, value: Variant) -> VarDictionary {
        reply(
            from_variant(&value)
                .and_then(|value| graffitty_protocol::graph::normalize_icon(&value))
                .map(|icon| json!({"icon":icon})),
        )
    }
    #[func]
    fn ports(&self, node: VarDictionary, output: bool) -> VarArray {
        let result = from_variant(&node.to_variant()).and_then(|value| {
            serde_json::from_value::<graffitty_protocol::graph::Node>(value)
                .map_err(|e| e.to_string())
        });
        match result {
            Ok(node) => to_variant(&json!(node.ports(output))).to(),
            Err(_) => VarArray::new(),
        }
    }
}
