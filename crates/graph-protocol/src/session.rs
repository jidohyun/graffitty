use crate::{Event, Manifest, Output, Result, Rpc};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

/// How a checkpoint relaunches a node, declared when it starts.
///
/// Never put secret values in the command or environment: keep a reference,
/// such as a credential name in secrets.toml, and resolve the secret again
/// after the relaunch.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize)]
pub struct Restore {
    pub command: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
}
impl Restore {
    /// This process's own command line and working directory.
    pub fn current_process() -> Result<Self> {
        let mut command: Vec<String> = std::env::args().collect();
        if command.is_empty() {
            return Err("Process has no command line".into());
        }
        command[0] = std::env::current_exe()?.to_string_lossy().into_owned();
        Ok(Self {
            command,
            cwd: Some(std::env::current_dir()?.to_string_lossy().into_owned()),
            env: BTreeMap::new(),
        })
    }
}
/// The state a node reported before the checkpoint that relaunched it.
pub fn restored_state() -> Result<Option<Value>> {
    let Some(path) = std::env::var_os("GRAFFITTY_NODE_STATE") else {
        return Ok(None);
    };
    Ok(Some(serde_json::from_slice(&std::fs::read(path)?)?))
}

/// Owns registration lifetime. Dropping it sends SessionEnd, including on errors.
/// UI nodes keep their own loops and use this without adopting the handler runtime.
pub struct Session<R: Rpc> {
    rpc: R,
    heartbeat: Instant,
    identity: Value,
}
impl<R: Rpc> Session<R> {
    pub fn start(rpc: R, resume_inbox: bool) -> Result<Self> {
        Self::start_with_provider(rpc, None, resume_inbox)
    }
    /// Providers identify real integrations; a generic node leaves this absent.
    /// Process identity never manufactures a conversation/session reference.
    pub fn start_with_provider(rpc: R, provider: Option<&str>, resume_inbox: bool) -> Result<Self> {
        Self::begin(rpc, provider, resume_inbox, None)
    }
    /// Opt in to checkpoint recovery: a restore runs `restore` in this
    /// node's pane, and `restored_state` returns its last reported state.
    pub fn start_restorable(rpc: R, provider: Option<&str>, resume_inbox: bool, restore: &Restore) -> Result<Self> {
        Self::begin(rpc, provider, resume_inbox, Some(restore))
    }
    fn begin(rpc: R, provider: Option<&str>, resume_inbox: bool, restore: Option<&Restore>) -> Result<Self> {
        let mut event = json!({"kind":"custom","event":"SessionStart",
            "pid":std::process::id(),"resume_inbox":resume_inbox,"transport":"inbox"});
        if let Some(provider) = provider {
            event["provider"] = json!(provider);
        }
        if let Some(restore) = restore {
            event["restore"] = serde_json::to_value(restore)?;
        }
        rpc.call("agent.event", event)?;
        let mut identity = json!({"kind":"custom"});
        if let Some(provider) = provider {
            identity["provider"] = json!(provider);
        }
        Ok(Self {
            rpc,
            heartbeat: Instant::now(),
            identity,
        })
    }
    /// Native provider bridges share lifecycle, heartbeat and inbox handling with
    /// custom nodes, while retaining the host's built-in Read/Send/Completed ports.
    pub fn start_agent(rpc: R, provider: &str, fields: Value) -> Result<Self> {
        let mut event = fields.as_object().cloned().ok_or("Expected agent fields")?;
        event.extend(
            json!({"kind":"agent","provider":provider,"event":"SessionStart",
            "transport":"inbox","integrated":true})
            .as_object()
            .unwrap()
            .clone(),
        );
        event.entry("pid").or_insert(json!(std::process::id()));
        rpc.call("agent.event", Value::Object(event))?;
        Ok(Self {
            rpc,
            heartbeat: Instant::now(),
            identity: json!({"kind":"agent","provider":provider}),
        })
    }
    pub fn call(&self, method: &str, params: Value) -> Result<Value> {
        self.rpc.call(method, params)
    }
    /// Report lifecycle metadata or a completed turn (Stop). Identity is owned
    /// by this session, and cannot be changed through the supplied fields.
    pub fn event(&self, event: &str, fields: Value) -> Result<Value> {
        let mut params = fields.as_object().cloned().ok_or("Expected event fields")?;
        params.remove("provider");
        params.extend(self.identity.as_object().unwrap().clone());
        params.insert("event".into(), json!(event));
        self.call("agent.event", Value::Object(params))
    }
    /// Keep `state`, any JSON up to 64 KiB, for this node's next relaunch from
    /// a checkpoint; null clears it. Never include secret values.
    pub fn report_state(&self, state: Value) -> Result<()> {
        self.call("agent.checkpoint", json!({"state":state}))?;
        Ok(())
    }
    pub fn register(&self, manifest: &Manifest) -> Result<()> {
        manifest.validate()?;
        self.register_raw(serde_json::to_value(manifest)?)
    }
    /// Accept dynamic application manifests, validated by the same host schema.
    pub fn register_raw(&self, manifest: Value) -> Result<()> {
        let manifest = graffitty_protocol::graph::normalize_manifest(&manifest)?;
        self.call("agent.register", manifest)?;
        Ok(())
    }
    pub fn heartbeat(&mut self) -> Result<()> {
        if self.heartbeat.elapsed() >= Duration::from_secs(5) {
            self.call("agent.heartbeat", json!({}))?;
            self.heartbeat = Instant::now();
        }
        Ok(())
    }
    pub fn take_raw(&self) -> Result<Vec<Value>> {
        self.call("graph.take", json!({}))?["events"]
            .as_array()
            .cloned()
            .ok_or_else(|| "Invalid host inbox response".into())
    }
    pub fn take(&self) -> Result<Vec<Event>> {
        self.take_raw()?
            .into_iter()
            .map(|v| Ok(serde_json::from_value(v)?))
            .collect()
    }
    pub fn ack(&self, event_id: &str) -> Result<()> {
        self.ack_with_status(event_id, "delivered")
    }
    pub fn ack_with_status(&self, event_id: &str, status: &str) -> Result<()> {
        self.call("graph.ack", json!({"event_id":event_id,"status":status}))?;
        Ok(())
    }
    pub fn forward(&self, event_id: &str, output: &Output) -> Result<Value> {
        output.validate()?;
        self.forward_raw(
            event_id,
            &output.port,
            Value::Object(output.content.clone()),
        )
    }
    /// Start a message on a Send output. Unlike forward, this has no parent
    /// event; an omitted payload is sent as null. The host owns fan-out and limits.
    pub fn emit(
        &self,
        output: &Output,
        run_id: Option<&str>,
        outcome: Option<&str>,
    ) -> Result<Value> {
        output.validate()?;
        let mut params = output.content.clone();
        params.entry("payload").or_insert(Value::Null);
        params.insert("output".into(), json!(output.port));
        if let Some(run_id) = run_id {
            params.insert("run_id".into(), json!(run_id));
        }
        if let Some(outcome) = outcome {
            params.insert("outcome".into(), json!(outcome));
        }
        let result = self.call("graph.emit", Value::Object(params))?;
        if result["status"] != "queued" {
            return Err("Output was not queued".into());
        }
        Ok(result)
    }
    pub fn forward_raw(&self, event_id: &str, output: &str, content: Value) -> Result<Value> {
        let result = self.call(
            "graph.forward",
            json!({"event_id":event_id,"output":output,"content":content}),
        )?;
        if result["status"] != "queued" {
            return Err("Output was not queued; input retained".into());
        }
        Ok(result)
    }
    pub fn progress(
        &self,
        event_id: &str,
        status: &str,
        message: &str,
        details: Value,
    ) -> Result<()> {
        if !["pending", "failed"].contains(&status) {
            return Err("Invalid progress status".into());
        }
        self.call(
            "graph.progress",
            json!({"event_id":event_id,"status":status,"message":message,"details":details}),
        )?;
        Ok(())
    }
}
impl<R: Rpc> Drop for Session<R> {
    fn drop(&mut self) {
        let _ = self.event("SessionEnd", json!({}));
    }
}
