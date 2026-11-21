use graffitty_session_transport::local_json::Stream;
use serde_json::{Value, json};
use std::{
    fmt,
    io::{self, BufRead, BufReader, Read, Write},
    time::Duration,
};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
pub const MAX_REQUEST: usize = 4 * 1024 * 1024;
pub const MAX_MESSAGE: u64 = MAX_REQUEST as u64 + 68 * 1024;

pub fn read_message(reader: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    if reader.take(MAX_MESSAGE + 1).read_until(b'\n', &mut bytes)? == 0 {
        return Ok(None);
    }
    if bytes.len() as u64 > MAX_MESSAGE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "API message too large",
        ));
    }
    if bytes.last() != Some(&b'\n') {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "Incomplete API message",
        ));
    }
    Ok(Some(bytes))
}

/// An injectable transport; tests and applications with their own context resolver
/// can use a closure without reimplementing node lifecycle or delivery handling.
pub trait Rpc {
    fn call(&self, method: &str, params: Value) -> Result<Value>;
}
impl<F: Fn(&str, Value) -> Result<Value>> Rpc for F {
    fn call(&self, method: &str, params: Value) -> Result<Value> {
        self(method, params)
    }
}

#[derive(Clone)]
pub struct Client {
    endpoint: String,
    token: String,
    timeout: Duration,
}
impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client")
            .field("endpoint", &self.endpoint)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

impl Client {
    pub fn new(endpoint: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            token: token.into(),
            timeout: Duration::from_secs(5),
        }
    }
    /// The pane this process runs in. Inside tmux the inherited variables may
    /// belong to another pane, so the pane is claimed instead (OSC 4723).
    pub fn from_env() -> Result<Self> {
        if let Some((endpoint, token)) = crate::tmux_context()? {
            return Ok(Self::new(endpoint, token));
        }
        let endpoint = std::env::var("GRAFFITTY_SOCKET").unwrap_or_default();
        let token = std::env::var("GRAFFITTY_TOKEN").unwrap_or_default();
        if endpoint.is_empty() || token.is_empty() {
            return Err("Run inside a Graffitty pane (GRAFFITTY_SOCKET/TOKEN required)".into());
        }
        Ok(Self::new(endpoint, token))
    }
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Preserve the RPC envelope for CLI/MCP callers that present host errors as JSON.
    pub fn exchange(&self, method: &str, params: Value) -> Result<Value> {
        if !params.is_object() {
            return Err("Expected a JSON object".into());
        }
        let id = uuid::Uuid::new_v4().to_string();
        let request =
            json!({"id":id,"version":1,"token":self.token,"method":method,"params":params});
        let mut bytes = serde_json::to_vec(&request)?;
        bytes.push(b'\n');
        if bytes.len() > MAX_REQUEST {
            return Err(format!("API request is {} bytes; Graffitty accepts at most {MAX_REQUEST}. Save long content to a file and send its path.", bytes.len()).into());
        }
        let mut socket = Stream::connect(&self.endpoint)?;
        socket.set_read_timeout(Some(self.timeout))?;
        socket.set_write_timeout(Some(self.timeout))?;
        socket.grow_send_buffer(bytes.len());
        socket.write_all(&bytes)?;
        let bytes =
            read_message(&mut BufReader::new(socket))?.ok_or("Host closed the API connection")?;
        let value: Value = serde_json::from_slice(&bytes)?;
        if value.get("id") != Some(&json!(id)) {
            return Err("Mismatched API response ID".into());
        }
        if !value.is_object() || (value.get("result").is_some() == value.get("error").is_some()) {
            return Err("Invalid API response".into());
        }
        Ok(value)
    }
}
impl Rpc for Client {
    fn call(&self, method: &str, params: Value) -> Result<Value> {
        response(method, self.exchange(method, params)?)
    }
}

pub fn response(method: &str, value: Value) -> Result<Value> {
    if let Some(error) = value.get("error") {
        return Err(format!(
            "{method}: {}",
            error["message"].as_str().unwrap_or("Host rejected request")
        )
        .into());
    }
    value
        .get("result")
        .cloned()
        .ok_or_else(|| "Invalid API response".into())
}
