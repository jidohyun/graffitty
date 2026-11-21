//! Shared configuration precedence for built-in and example nodes.
use crate::agent_bridge::Result;
use serde_json::Value;

pub fn merge(base: &mut Value, patch: Value) -> Result<()> {
    let object = patch
        .as_object()
        .ok_or("Node settings must be a JSON object")?;
    for (key, value) in object {
        base.as_object_mut()
            .ok_or("Invalid settings defaults")?
            .insert(key.clone(), value.clone());
    }
    Ok(())
}

pub fn load(defaults: Value, path: Option<&str>) -> Result<Value> {
    let mut settings = defaults;
    let env_path = std::env::var("GRAFFITTY_NODE_CONFIG").ok();
    if let Some(path) = path.or(env_path.as_deref()) {
        merge(
            &mut settings,
            serde_json::from_str(&std::fs::read_to_string(path)?)?,
        )?;
    }
    Ok(settings)
}
