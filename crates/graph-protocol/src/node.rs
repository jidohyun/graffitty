use crate::{
    Client, Event, Icon, InputPort, Manifest, Output, OutputPort, PortMode, Restore, Result, Rpc,
    Session,
};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};

pub trait IntoOutputs {
    fn into_outputs(self) -> Vec<Output>;
}
impl IntoOutputs for Output {
    fn into_outputs(self) -> Vec<Output> {
        vec![self]
    }
}
impl IntoOutputs for Vec<Output> {
    fn into_outputs(self) -> Vec<Output> {
        self
    }
}
impl IntoOutputs for () {
    fn into_outputs(self) -> Vec<Output> {
        vec![]
    }
}
impl IntoOutputs for Option<Output> {
    fn into_outputs(self) -> Vec<Output> {
        self.into_iter().collect()
    }
}
type Handler = Box<dyn FnMut(&Event) -> Result<Vec<Output>>>;

pub struct Node {
    pub manifest: Manifest,
    provider: Option<String>,
    restorable: bool,
    handlers: HashMap<String, Handler>,
}
impl Node {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            manifest: Manifest::new(name),
            provider: None,
            restorable: false,
            handlers: HashMap::new(),
        }
    }
    pub fn input(mut self, port: impl Into<InputPort>) -> Self {
        self.manifest.inputs.push(port.into());
        self
    }
    pub fn icon(mut self, icon: impl Into<Icon>) -> Self {
        self.manifest.icon = Some(icon.into());
        self
    }
    pub fn provider(mut self, provider: impl Into<String>) -> Self {
        self.provider = Some(provider.into());
        self
    }
    /// Let a checkpoint relaunch this node with its own command line.
    pub fn restorable(mut self) -> Self {
        self.restorable = true;
        self
    }
    pub fn output(mut self, port: impl Into<OutputPort>) -> Self {
        self.manifest.outputs.push(port.into());
        self
    }
    pub fn on<T: IntoOutputs, F: FnMut(&Event) -> Result<T> + 'static>(
        &mut self,
        input: &str,
        mut handler: F,
    ) -> Result<()> {
        if !self.manifest.inputs.iter().any(|p| p.id == input) {
            return Err(format!("Unknown input: {input}").into());
        }
        if self.handlers.contains_key(input) {
            return Err(format!("Handler already registered: {input}").into());
        }
        self.handlers.insert(
            input.into(),
            Box::new(move |event| handler(event).map(IntoOutputs::into_outputs)),
        );
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        self.manifest.validate()?;
        for port in &self.manifest.inputs {
            if !self.handlers.contains_key(&port.id) {
                return Err(format!("Missing handler: {}", port.id).into());
            }
        }
        Ok(())
    }
    /// Process one event, preserving the host's run and session references.
    /// Failures remain pending; callers decide when it is safe to retry.
    pub fn process<R: Rpc>(&mut self, session: &Session<R>, event: &Event) -> Result<()> {
        let result = (|| {
            let handler = self
                .handlers
                .get_mut(&event.target_port)
                .ok_or("No handler for input port")?;
            let outputs = handler(event)?;
            // Validate the entire result before sending any branch.
            for output in &outputs {
                output.validate()?;
                let port = self
                    .manifest
                    .outputs
                    .iter()
                    .find(|p| p.port.id == output.port)
                    .ok_or_else(|| format!("Unknown output: {}", output.port))?;
                if port.mode != PortMode::Send {
                    return Err(
                        format!("Handler outputs require Send mode: {}", output.port).into(),
                    );
                }
            }
            for output in outputs {
                session.forward(&event.event_id, &output)?;
            }
            session.ack(&event.event_id)
        })();
        if let Err(ref error) = result {
            let _ = session.progress(&event.event_id, "failed", &error.to_string(), json!({}));
        }
        result
    }
    /// Convenience entry point for a standalone binary. Embedders use run_until
    /// to retain ownership of their process's signal handling.
    pub fn run(self) -> Result<()> {
        self.validate()?;
        let client = Client::from_env()?;
        let stop = Arc::new(AtomicBool::new(false));
        let signal = stop.clone();
        ctrlc::set_handler(move || signal.store(true, Ordering::Relaxed))?;
        self.run_until(client, stop)
    }
    pub fn run_until(mut self, client: Client, stop: Arc<AtomicBool>) -> Result<()> {
        self.validate()?;
        let session = match self.restorable {
            true => Session::start_restorable(client.clone(), self.provider.as_deref(), true, &Restore::current_process()?)?,
            false => Session::start_with_provider(client.clone(), self.provider.as_deref(), true)?,
        };
        session.register(&self.manifest)?;
        // Heartbeats continue while a synchronous user handler is busy.
        let (end, done) = mpsc::channel::<()>();
        let (errors, error) = mpsc::channel();
        let heartbeat = std::thread::spawn(move || {
            while matches!(
                done.recv_timeout(Duration::from_secs(5)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ) {
                if let Err(e) = client.call("agent.heartbeat", json!({})) {
                    let _ = errors.send(e.to_string());
                    break;
                }
            }
        });
        let result = (|| {
            while !stop.load(Ordering::Relaxed) {
                if let Ok(error) = error.try_recv() {
                    return Err(error.into());
                }
                for raw in session.take_raw()? {
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                    let event = match serde_json::from_value(raw.clone()) {
                        Ok(event) => event,
                        Err(error) => {
                            if let Some(id) = raw["event_id"].as_str() {
                                let _ = session.progress(
                                    id,
                                    "failed",
                                    "Invalid graph event",
                                    json!({}),
                                );
                            }
                            return Err(error.into());
                        }
                    };
                    self.process(&session, &event)?;
                }
                std::thread::sleep(Duration::from_millis(250));
            }
            Ok(())
        })();
        drop(end);
        let _ = heartbeat.join();
        result
    }
}
