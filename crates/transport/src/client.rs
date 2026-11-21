//! Shared session messages over private IPC or an authenticated, encrypted
//! WebSocket/WSS.
//!
//! After the OPAQUE login every network message is a channel record keyed by
//! that login, so no network path, TLS or VPN is required for
//! confidentiality.
//!
//! Passwords stay in OPAQUE's zeroizing client state and are never persisted.
use crate::auth;
use crate::ipc::{self, Packet};
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs, io,
    net::{TcpStream, ToSocketAddrs},
    path::Path,
    time::{Duration, Instant},
};
use tungstenite::{
    Message, WebSocket,
    client::IntoClientRequest,
    protocol::{CloseFrame, WebSocketConfig},
    stream::MaybeTlsStream,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const AUTH_TIMEOUT: Duration = Duration::from_secs(30);
use graffitty_protocol::DEFAULT_REMOTE_PORT;
pub type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

pub enum ClientTransport {
    Local(ipc::Peer),
    Network(Box<NetworkPeer>),
}

pub enum Readiness {
    Local(ipc::Readiness),
    Network(TcpStream),
}
impl Readiness {
    pub fn is_ready(&self) -> bool {
        match self {
            Self::Local(peer) => peer.is_ready(),
            Self::Network(stream) => match stream.peek(&mut [0]) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => false,
                _ => true,
            },
        }
    }
}

impl ClientTransport {
    pub fn readiness(&self) -> Result<Readiness> {
        Ok(match self {
            Self::Local(peer) => Readiness::Local(peer.readiness()?),
            Self::Network(peer) => Readiness::Network(tcp(&peer.socket)?.try_clone()?),
        })
    }
    pub fn local_peer_pid(&self) -> Option<u32> {
        match self { Self::Local(peer) => peer.local_peer_pid(), Self::Network(_) => None }
    }
    pub fn send(&mut self, packet: Packet) -> io::Result<()> {
        match self {
            Self::Local(peer) => peer.send(packet),
            Self::Network(peer) => peer.send(packet),
        }
    }

    pub fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Local(peer) => peer.flush(),
            Self::Network(peer) => peer.socket.flush().map_err(socket_error),
        }
    }

    pub fn read(&mut self) -> io::Result<Packet> {
        match self {
            Self::Local(peer) => peer.read(),
            Self::Network(peer) => peer.read(),
        }
    }

    pub fn is_remote(&self) -> bool {
        matches!(self, Self::Network(_))
    }

    /// Display identity learned from the authenticated owner's ready message.
    pub fn remote_hostname(&self) -> &str {
        match self { Self::Network(peer) => &peer.hostname, Self::Local(_) => "" }
    }
}

/// A WebSocket that carries only encrypted channel records. Plaintext, forged,
/// replayed or reordered records end the connection.
pub struct NetworkPeer {
    socket: Socket,
    channel: auth::Channel,
    failed: bool,
    hostname: String,
}

impl NetworkPeer {
    pub fn new(socket: Socket, channel: auth::Channel) -> Self {
        Self { socket, channel, failed: false, hostname: String::new() }
    }

    fn send(&mut self, packet: Packet) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::new(io::ErrorKind::NotConnected, "Encrypted connection failed"));
        }
        let (kind, bytes) = match packet {
            Packet::Text(bytes) => (auth::Kind::Text, bytes),
            Packet::Binary(bytes) => (auth::Kind::Binary, bytes),
        };
        if bytes.len() > ipc::MAX_PACKET {
            return Err(io::Error::other("Session output limit reached"));
        }
        let record = self.channel.seal(kind, &bytes).map_err(io::Error::other)?;
        // Tungstenite owns a message once it reports WouldBlock; it is
        // queued for flush. Retrying send here would duplicate input.
        match self.socket.send(Message::Binary(record.into())) {
            Err(tungstenite::Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => Ok(()),
            Err(error) => {
                // A numbered record that was never queued breaks the sequence.
                self.failed = true;
                Err(socket_error(error))
            }
            Ok(()) => Ok(()),
        }
    }

    fn read(&mut self) -> io::Result<Packet> {
        if self.failed {
            return Err(io::Error::new(io::ErrorKind::NotConnected, "Encrypted connection failed"));
        }
        loop {
            match self.socket.read().map_err(socket_error)? {
                Message::Binary(record) => {
                    let (kind, bytes) = self.channel.open(&record).map_err(|error| {
                        self.failed = true;
                        io::Error::new(io::ErrorKind::InvalidData, error)
                    })?;
                    return Ok(match kind {
                        auth::Kind::Text => Packet::Text(bytes),
                        auth::Kind::Binary => Packet::Binary(bytes),
                    });
                }
                Message::Text(_) => {
                    self.failed = true;
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Unencrypted message on an encrypted connection",
                    ));
                }
                Message::Close(frame) => {
                    return Err(io::Error::new(io::ErrorKind::ConnectionAborted, closed(frame)));
                }
                // Ping is answered by Tungstenite, including when a flush
                // has to wait until the next frame's nonblocking poll.
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        }
    }
}

fn closed(frame: Option<CloseFrame>) -> String {
    frame
        .map(|f| f.reason.to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Remote server disconnected".into())
}

fn socket_error(error: tungstenite::Error) -> io::Error {
    match error {
        tungstenite::Error::Io(error) => error,
        tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed => {
            io::Error::new(io::ErrorKind::NotConnected, "Remote server disconnected")
        }
        tungstenite::Error::WriteBufferFull(_) => io::Error::other("Session output limit reached"),
        error => io::Error::other(error.to_string()),
    }
}

fn tcp(socket: &Socket) -> Result<&TcpStream> {
    match socket.get_ref() {
        MaybeTlsStream::Plain(stream) => Ok(stream),
        #[cfg(not(target_os = "android"))]
        MaybeTlsStream::NativeTls(stream) => Ok(stream.get_ref()),
        #[cfg(target_os = "android")]
        MaybeTlsStream::Rustls(stream) => Ok(&stream.sock),
        _ => bail!("Unsupported TLS stream"),
    }
}

fn connect(url: &str) -> Result<Socket> {
    let request = validated_request(url)?;
    let uri = request.uri();
    let host = uri
        .host()
        .context("Missing remote host")?
        .trim_start_matches('[')
        .trim_end_matches(']');
    let port = uri
        .port_u16()
        .unwrap_or(if uri.scheme_str() == Some("wss") {
            443
        } else {
            80
        });
    let mut stream = None;
    let mut last_error = None;
    let started = Instant::now();
    for address in (host, port)
        .to_socket_addrs()
        .context("Resolve remote host")?
    {
        let Some(remaining) = CONNECT_TIMEOUT.checked_sub(started.elapsed()) else {
            break;
        };
        match TcpStream::connect_timeout(&address, remaining) {
            Ok(connected) => {
                stream = Some(connected);
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let stream = stream.ok_or_else(|| {
        anyhow!(
            last_error
                .map(|e| e.to_string())
                .unwrap_or_else(|| "Connection timed out".into())
        )
    })?;
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(CONNECT_TIMEOUT))?;
    stream.set_write_timeout(Some(CONNECT_TIMEOUT))?;
    let limit = ipc::MAX_PACKET + auth::CHANNEL_OVERHEAD;
    let config = WebSocketConfig::default()
        .write_buffer_size(0)
        .max_write_buffer_size(ipc::MAX_PENDING)
        .max_message_size(Some(limit))
        .max_frame_size(Some(limit));
    // Native TLS validates hostname and the platform trust chain; there is no
    // insecure-certificate fallback and WSS is never downgraded to plaintext.
    // Plain ws:// is still encrypted end to end by the login's channel.
    let (socket, _) = tungstenite::client_tls_with_config(request, stream, Some(config), None)
        .map_err(|error| anyhow!("WebSocket handshake failed: {error}"))?;
    tcp(&socket)?.set_read_timeout(Some(AUTH_TIMEOUT))?;
    Ok(socket)
}

/// Accept a host[:port] at the UI boundary and keep one explicit server URL.
/// Explicit WSS endpoints retain HTTPS's standard port for TLS proxies.
pub fn normalize_server_url(url: &str) -> Result<String> {
    ensure!(
        url.len() <= 4096 && !url.chars().any(char::is_control),
        "Invalid remote URL"
    );
    let address = url.trim();
    ensure!(!address.is_empty(), "Enter a server address");
    let expanded = if address.contains("://") {
        address.to_owned()
    } else if address.parse::<std::net::Ipv6Addr>().is_ok() {
        format!("ws://[{address}]")
    } else {
        format!("ws://{address}")
    };
    let uri: tungstenite::http::Uri = expanded.parse().context("Invalid server address")?;
    ensure!(
        matches!(uri.scheme_str(), Some("ws" | "wss")),
        "Use ws:// or wss://"
    );
    ensure!(
        !uri
            .authority()
            .is_some_and(|a| a.as_str().contains('@')),
        "Enter the password separately from the URL"
    );
    let authority = uri.authority().context("Missing remote host")?;
    ensure!(!authority.host().is_empty(), "Missing remote host");
    let suffix = authority.as_str().strip_prefix(authority.host()).unwrap_or("");
    ensure!(suffix.is_empty() || (suffix.starts_with(':') && authority.port_u16().is_some()), "Invalid server port");
    ensure!(!authority.as_str().ends_with(':') && (authority.port().is_none() || authority.port_u16().is_some_and(|port| port > 0)), "Invalid server port");
    let authority = if authority.port().is_none() && uri.scheme_str() == Some("ws") {
        format!("{authority}:{DEFAULT_REMOTE_PORT}")
    } else {
        authority.to_string()
    };
    let path = uri.path_and_query().map(|path| path.as_str()).unwrap_or("");
    Ok(format!("{}://{authority}{}", uri.scheme_str().unwrap(), if path == "/" { "" } else { path }))
}

fn validated_request(url: &str) -> Result<tungstenite::handshake::client::Request> {
    let request = normalize_server_url(url)?.into_client_request().context("Invalid WebSocket URL")?;
    Ok(request)
}

/// The login exchange: plaintext until the password is verified, then the
/// encrypted channel for everything, including the Telegram code.
struct Handshake {
    socket: Socket,
    channel: Option<auth::Channel>,
}

impl Handshake {
    fn send_json(&mut self, value: &Value) -> Result<()> {
        let text = value.to_string();
        let message = match &mut self.channel {
            Some(channel) => Message::Binary(
                channel
                    .seal(auth::Kind::Text, text.as_bytes())
                    .map_err(anyhow::Error::msg)?
                    .into(),
            ),
            None => Message::Text(text.into()),
        };
        self.socket.send(message)?;
        Ok(())
    }

    fn read_json(&mut self) -> Result<Value> {
        loop {
            let text = match (self.socket.read()?, &mut self.channel) {
                (Message::Text(text), None) => text.as_bytes().to_vec(),
                (Message::Binary(record), Some(channel)) => {
                    match channel.open(&record).map_err(anyhow::Error::msg)? {
                        (auth::Kind::Text, text) => text,
                        _ => bail!("Unexpected binary data before authentication"),
                    }
                }
                (Message::Close(frame), _) => bail!("{}", closed(frame)),
                (Message::Ping(_) | Message::Pong(_), _) => continue,
                (Message::Text(_), Some(_)) => {
                    bail!("Unencrypted message after the password was verified")
                }
                _ => bail!("Unexpected binary data before authentication"),
            };
            return serde_json::from_slice(&text).context("Invalid authentication response");
        }
    }

    fn connected(self, response: &Value) -> Result<ClientTransport> {
        ensure!(
            response["version"] == graffitty_protocol::VERSION,
            "Unsupported remote protocol; update the client and server"
        );
        let channel = self
            .channel
            .context("Server did not open the encrypted channel")?;
        tcp(&self.socket)?.set_read_timeout(None)?;
        tcp(&self.socket)?.set_write_timeout(None)?;
        tcp(&self.socket)?.set_nonblocking(true)?;
        let mut peer = NetworkPeer::new(self.socket, channel);
        peer.hostname = response["hostname"].as_str().unwrap_or_default().into();
        Ok(ClientTransport::Network(Box::new(peer)))
    }
}

pub enum Authentication {
    Connected(ClientTransport),
    CodeRequired(PendingCode),
}

/// A verified password exchange waiting for the user's Telegram second factor.
pub struct PendingCode {
    handshake: Handshake,
    key: auth::Key,
    deadline: Instant,
}

impl PendingCode {
    pub fn submit(mut self, code: &str) -> Result<ClientTransport> {
        ensure!(
            Instant::now() < self.deadline,
            "Telegram code expired; connect again"
        );
        ensure!(
            code.len() == 6 && code.bytes().all(|c| c.is_ascii_digit()),
            "Enter the six-digit Telegram code"
        );
        let proof = self.key.code_proof(code);
        self.handshake
            .send_json(&json!({"type":"auth_code","proof":proof}))?;
        loop {
            let response = self.handshake.read_json()?;
            match response["type"].as_str() {
                Some("ready") => return self.handshake.connected(&response),
                Some("error") => bail!("{}", server_error(&response)),
                _ => bail!("Unexpected response after Telegram verification"),
            }
        }
    }
}

pub fn authenticate(
    url: &str,
    password: &str,
    code: Option<&str>,
) -> Result<Authentication> {
    authenticate_with_capabilities(url, password, code, &serde_json::Map::new())
}

/// Frontends advertise media decoders only after installing a matching decoder
/// path. CLI callers keep the portable default capability set.
pub fn authenticate_with_capabilities(
    url: &str,
    password: &str,
    code: Option<&str>,
    capabilities: &serde_json::Map<String, Value>,
) -> Result<Authentication> {
    let mut context = json!({"type":"auth_start","version":graffitty_protocol::VERSION,"features":["bell"],"chromium_image_format":"png"});
    for key in ["features", "chromium_image_format", "chromium_video"] {
        if let Some(value) = capabilities.get(key) { context[key] = value.clone(); }
    }
    let binding = auth::wire::context(&context).map_err(anyhow::Error::msg)?;
    let (client, message) = auth::Client::start(password, &binding).map_err(anyhow::Error::msg)?;
    let mut client = Some(client);
    let mut handshake = Handshake { socket: connect(url)?, channel: None };
    context["message"] = json!(message);
    handshake.send_json(&context)?;
    let mut key = None;
    let deadline = Instant::now() + AUTH_TIMEOUT;
    loop {
        ensure!(Instant::now() < deadline, "Authentication timed out");
        let response = handshake.read_json()?;
        match response["type"].as_str() {
            Some("auth_challenge") => {
                let client = client.take().context("Unexpected password challenge")?;
                let (verified, finish) = client
                    .finish(
                        response["message"]
                            .as_str()
                            .context("Missing password challenge")?,
                    )
                    .map_err(anyhow::Error::msg)?;
                handshake.send_json(&json!({"type":"auth_finish","message":finish}))?;
                // The server answers auth_finish only on the encrypted channel.
                handshake.channel = Some(verified.channel(auth::Role::Client));
                key = Some(verified);
            }
            Some("auth_wait") => ensure!(key.is_some(), "Server did not verify the password"),
            Some("auth_code_required") => {
                let key = key.context("Server did not verify the password")?;
                let expires = response["expires_in"].as_u64().unwrap_or(120).min(120);
                let pending = PendingCode {
                    handshake,
                    key,
                    deadline: Instant::now() + Duration::from_secs(expires),
                };
                return match code {
                    Some(code) => Ok(Authentication::Connected(pending.submit(code)?)),
                    None => Ok(Authentication::CodeRequired(pending)),
                };
            }
            Some("ready") => {
                ensure!(key.is_some(), "Server did not verify the password");
                return Ok(Authentication::Connected(handshake.connected(&response)?));
            }
            Some("error") => bail!("{}", server_error(&response)),
            _ => bail!("Unexpected message before authentication"),
        }
    }
}

fn server_error(response: &Value) -> &str {
    response["message"]
        .as_str()
        .or_else(|| response["error"].as_str())
        .unwrap_or("Authentication rejected")
}

/// Remote Chromium video limits sent as the `chromium_stream` capability;
/// zero means Auto. Auto resolution follows the displayed pane up to 1440p.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct StreamQuality {
    pub max_height: u32,
    pub fps: u32,
    pub bitrate_kbps: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SavedConnection {
    pub name: String,
    /// Exact CLI identity, independent of the display label. Empty selects a
    /// persistent default once the authenticated hostname is known.
    #[serde(default)]
    pub alias: String,
    pub url: String,
    #[serde(default)]
    pub hostname: String,
    /// Display metadata learned only after authenticating, absent until then.
    #[serde(default)]
    pub platform: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub remember: bool,
    /// A preference, absent until chosen: Auto.
    #[serde(default)]
    pub chromium_stream: StreamQuality,
}

impl SavedConnection {
    fn validate(&self) -> Result<()> {
        ensure!(self.alias.is_empty() || graffitty_protocol::controller::valid_alias(&self.alias), "Invalid server alias");
        ensure!(
            self.name.len() <= 128 && !self.name.chars().any(char::is_control),
            "Invalid connection name"
        );
        ensure!(self.hostname.len() <= 255 && !self.hostname.chars().any(char::is_control), "Invalid server hostname");
        ensure!(self.platform.len() <= 32 && !self.platform.chars().any(char::is_control), "Invalid server platform");
        ensure!(self.username.len() <= 255 && !self.username.chars().any(char::is_control), "Invalid server username");
        let stream = self.chromium_stream;
        ensure!(
            stream.max_height <= 2160 && stream.fps <= 60 && stream.bitrate_kbps <= 200_000,
            "Invalid Chromium stream quality"
        );
        validated_request(&self.url)?;
        Ok(())
    }
}

pub fn load_connections(path: &Path) -> Result<Vec<SavedConnection>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        bytes.len() <= 256 * 1024,
        "Saved connections file is too large"
    );
    let connections: Vec<SavedConnection> =
        serde_json::from_slice(&bytes).context("Invalid saved connections")?;
    ensure!(connections.len() <= 64, "Too many saved connections");
    for connection in &connections {
        connection.validate()?;
    }
    validate_aliases(&connections)?;
    Ok(connections)
}

pub fn save_connections(path: &Path, connections: &[SavedConnection]) -> Result<()> {
    use io::Write;
    ensure!(connections.len() <= 64, "Too many saved connections");
    for connection in connections {
        connection.validate()?;
    }
    validate_aliases(connections)?;
    let parent = path.parent().context("Missing connections directory")?;
    fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer_pretty(&mut file, connections)?;
    file.write_all(b"\n")?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Move a saved server without rewriting credentials or
/// connection identity. The existing array is the single persisted order.
pub fn reorder_connections(path: &Path, source: &str, target: &str, before: bool) -> Result<()> {
    let source = normalize_server_url(source)?;
    let target = normalize_server_url(target)?;
    let mut entries = load_connections(path)?;
    ensure!(entries.iter().any(|entry| entry.url == source), "Source server is not saved");
    ensure!(entries.iter().any(|entry| entry.url == target), "Target server is not saved");
    if source == target { return Ok(()); }
    let mut urls: Vec<String> = Vec::new();
    for entry in &entries {
        if entry.url != source && !urls.contains(&entry.url) { urls.push(entry.url.clone()); }
    }
    let index = urls.iter().position(|url| url == &target).expect("validated target");
    urls.insert(index + usize::from(!before), source);
    // Reordering changes only the saved-server order, never its metadata.
    entries.sort_by_key(|entry| urls.iter().position(|url| url == &entry.url).expect("known server"));
    save_connections(path, &entries)
}

/// Update the server identity without ever accepting credentials in
/// the persisted document. Read failures must not overwrite the saved list.
pub fn upsert_connection(path: &Path, mut connection: SavedConnection) -> Result<SavedConnection> {
    connection.url = normalize_server_url(&connection.url)?;
    connection.validate()?;
    // Several windows can authenticate together. Reserve generated aliases in
    // one read/modify/write transaction, including when the file is new.
    fs::create_dir_all(path.parent().context("Missing connections directory")?)?;
    let lock = fs::OpenOptions::new().create(true).truncate(false).write(true)
        .open(path.with_extension("lock"))?;
    lock.lock()?;
    let mut connections = load_connections(path)?;
    for entry in &mut connections { entry.url = normalize_server_url(&entry.url)?; }
    if connection.alias.is_empty() {
        connection.alias = connections.iter()
            .find(|entry| entry.url == connection.url && !entry.alias.is_empty())
            .map(|entry| entry.alias.clone()).unwrap_or_default();
        if connection.alias.is_empty() && !connection.hostname.is_empty() {
            connection.alias = hostname_alias(&connection.hostname, |alias| {
                connections.iter().any(|entry| entry.url != connection.url && entry.alias == alias)
            });
        }
    }
    if let Some(existing) = connections.iter_mut().find(|entry| entry.url == connection.url) {
        *existing = connection.clone();
    } else {
        connections.push(connection.clone());
    }
    save_connections(path, &connections)?;
    Ok(connection)
}

/// A hostname seeds the address once; later hostname/display-name changes do
/// not rename it. Unsupported characters become separators, never path syntax.
fn hostname_alias(hostname: &str, taken: impl Fn(&str) -> bool) -> String {
    let mut base = String::new();
    for character in hostname.chars() {
        if base.len() == 64 { break; }
        if character.is_ascii_alphanumeric() || "-_.".contains(character) {
            base.push(character.to_ascii_lowercase());
        } else if !base.ends_with('-') {
            base.push('-');
        }
    }
    let base = base.trim_matches(['-', '_', '.']);
    let base = if base.is_empty() { "server" } else { base };
    let mut alias = base.to_owned();
    let mut suffix = 2;
    while taken(&alias) {
        let ending = format!("-{suffix}");
        alias = format!("{}{}", &base[..base.len().min(64 - ending.len())], ending);
        suffix += 1;
    }
    alias
}

fn validate_aliases(connections: &[SavedConnection]) -> Result<()> {
    let mut aliases = std::collections::BTreeMap::new();
    let mut servers = std::collections::BTreeMap::new();
    for entry in connections {
        let url = normalize_server_url(&entry.url)?;
        ensure!(servers.insert(url.clone(), &entry.alias).is_none(), "Server is saved more than once");
        if entry.alias.is_empty() { continue; }
        if let Some(previous) = aliases.insert(&entry.alias, url.clone()) {
            ensure!(previous == url, "Server alias is already assigned to another server");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{Arc, Mutex, mpsc},
        thread,
    };

    type Server = WebSocket<TcpStream>;

    #[test]
    fn server_address_defaults_preserve_explicit_endpoints() {
        for (input, expected) in [
            (" desktop.local ", "ws://desktop.local:7183"),
            ("desktop.local:9000", "ws://desktop.local:9000"),
            ("ws://desktop.local", "ws://desktop.local:7183"),
            ("127.0.0.1", "ws://127.0.0.1:7183"),
            ("::1", "ws://[::1]:7183"),
            ("[::1]:9000", "ws://[::1]:9000"),
            ("ws://desktop.local:80/terminal?view=main", "ws://desktop.local:80/terminal?view=main"),
            ("wss://example.test/terminal", "wss://example.test/terminal"),
            ("wss://example.test:9443", "wss://example.test:9443"),
        ] {
            assert_eq!(normalize_server_url(input).unwrap(), expected, "{input}");
            assert!(validated_request(input).is_ok(), "{input}");
        }
        for input in ["", "ws://", "https://example.test", "user:password@example.test", "host:bad", "host:65536", "host:0", "host:", "host\n/path", "host name"] {
            assert!(normalize_server_url(input).is_err(), "{input}");
        }
    }

    fn sealed(channel: &mut auth::Channel, value: Value) -> Message {
        Message::Binary(channel.seal(auth::Kind::Text, value.to_string().as_bytes()).unwrap().into())
    }

    fn opened(channel: &mut auth::Channel, message: Message) -> Result<Value> {
        let (kind, bytes) = channel.open(&message.into_data()).map_err(anyhow::Error::msg)?;
        ensure!(kind == auth::Kind::Text);
        Ok(serde_json::from_slice(&bytes)?)
    }

    /// A one-connection server that runs the real login and then `after` on
    /// the encrypted channel.
    fn serve(
        factor: bool,
        after: impl FnOnce(&mut Server, &mut auth::Channel) -> Result<()> + Send + 'static,
    ) -> (std::net::SocketAddr, mpsc::Receiver<String>, thread::JoinHandle<Result<()>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || -> Result<()> {
            let (tcp, _) = listener.accept()?;
            tcp.set_read_timeout(Some(Duration::from_secs(5)))?;
            let mut socket = tungstenite::accept(tcp)?;
            let start: Value = serde_json::from_str(socket.read()?.to_text()?)?;
            assert_eq!(start["type"], "auth_start");
            assert!(start.get("password").is_none() && start.get("token").is_none());
            let mut server = auth::Server::new(auth::Config::default(), "test-secret-password")
                .map_err(anyhow::Error::msg)?;
            let context = auth::wire::context(&start).map_err(anyhow::Error::msg)?;
            let (pending, message) = server
                .start(start["message"].as_str().unwrap(), &context)
                .map_err(anyhow::Error::msg)?;
            socket.send(Message::Text(
                json!({"type":"auth_challenge","message":message})
                    .to_string()
                    .into(),
            ))?;
            let finish: Value = serde_json::from_str(socket.read()?.to_text()?)?;
            let key = pending
                .finish(finish["message"].as_str().unwrap())
                .map_err(anyhow::Error::msg)?;
            let mut channel = key.channel(auth::Role::Server);
            if factor {
                let mut second = auth::SecondFactor::new(key);
                tx.send(second.code().to_string())?;
                socket.send(sealed(&mut channel, json!({"type":"auth_wait"})))?;
                socket.send(sealed(&mut channel, json!({"type":"auth_code_required","expires_in":120})))?;
                let answer = opened(&mut channel, socket.read()?)?;
                assert_eq!(answer["type"], "auth_code");
                assert!(answer.get("code").is_none());
                if !second.verify(answer["proof"].as_str().unwrap_or("")) {
                    socket.send(sealed(
                        &mut channel,
                        json!({"type":"error","message":"Invalid or expired Telegram code"}),
                    ))?;
                    return Ok(());
                }
            }
            socket.send(sealed(
                &mut channel,
                json!({"type":"ready","version":graffitty_protocol::VERSION,"workspace":"test","epoch":"test","hostname":"Build Host"}),
            ))?;
            after(&mut socket, &mut channel)
        });
        (address, rx, worker)
    }

    fn peer(
        factor: bool,
    ) -> (
        String,
        mpsc::Receiver<String>,
        thread::JoinHandle<Result<()>>,
    ) {
        let (address, rx, worker) = serve(factor, |socket, channel| {
            socket.send(Message::Binary(channel.seal(auth::Kind::Binary, &[1, 2, 3]).unwrap().into()))?;
            Ok(())
        });
        (format!("ws://{address}"), rx, worker)
    }

    fn connect_test(url: &str) -> ClientTransport {
        let Authentication::Connected(connection) =
            authenticate(url, "test-secret-password", None).unwrap()
        else {
            panic!("Unexpected 2FA");
        };
        assert_eq!(connection.remote_hostname(), "Build Host");
        connection
    }

    /// Copies TCP bytes both ways and keeps what an observer sees in each
    /// direction: client-to-server, then server-to-client.
    fn wiretap(target: std::net::SocketAddr) -> (String, [Arc<Mutex<Vec<u8>>>; 2]) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let captured = [Arc::new(Mutex::new(Vec::new())), Arc::new(Mutex::new(Vec::new()))];
        let logs = captured.clone();
        thread::spawn(move || {
            let (client, _) = listener.accept().unwrap();
            let server = TcpStream::connect(target).unwrap();
            for ((mut from, mut to), log) in [
                (client.try_clone().unwrap(), server.try_clone().unwrap()),
                (server, client),
            ]
            .into_iter()
            .zip(logs)
            {
                thread::spawn(move || {
                    let mut buffer = [0; 4096];
                    while let Ok(n @ 1..) = from.read(&mut buffer) {
                        log.lock().unwrap().extend_from_slice(&buffer[..n]);
                        if to.write_all(&buffer[..n]).is_err() {
                            break;
                        }
                    }
                    let _ = to.shutdown(std::net::Shutdown::Write);
                });
            }
        });
        (url, captured)
    }

    /// WebSocket payloads after the HTTP upgrade, with client masking removed:
    /// masking is not encryption, so the check must look underneath it.
    fn payloads(stream: &[u8]) -> Vec<u8> {
        let mut at = stream.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        let mut out = Vec::new();
        while at + 2 <= stream.len() {
            let masked = stream[at + 1] & 0x80 != 0;
            let mut length = usize::from(stream[at + 1] & 0x7f);
            at += 2;
            if length == 126 {
                length = usize::from(u16::from_be_bytes([stream[at], stream[at + 1]]));
                at += 2;
            } else if length == 127 {
                length = u64::from_be_bytes(stream[at..at + 8].try_into().unwrap()) as usize;
                at += 8;
            }
            let mask = masked.then(|| {
                at += 4;
                [stream[at - 4], stream[at - 3], stream[at - 2], stream[at - 1]]
            });
            let end = (at + length).min(stream.len());
            out.extend(
                stream[at..end]
                    .iter()
                    .enumerate()
                    .map(|(i, b)| mask.map_or(*b, |m| b ^ m[i % 4])),
            );
            at = end;
        }
        out
    }

    fn receive(connection: &mut ClientTransport) -> Packet {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match connection.read() {
                Ok(packet) => return packet,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(1))
                }
                Err(error) => panic!("{error}"),
            }
        }
    }

    #[test]
    fn opaque_loopback_connection_uses_the_packet_transport() {
        let (url, _, worker) = peer(false);
        let Authentication::Connected(mut connection) =
            authenticate(&url, "test-secret-password", None).unwrap()
        else {
            panic!("Unexpected 2FA");
        };
        assert!(matches!(receive(&mut connection),Packet::Binary(bytes) if bytes==[1,2,3]));
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn telegram_proof_uses_existing_challenge_without_delivery() {
        let (url, code, worker) = peer(true);
        let Authentication::CodeRequired(pending) =
            authenticate(&url, "test-secret-password", None).unwrap()
        else {
            panic!("2FA was bypassed");
        };
        let mut connection = pending.submit(&code.recv().unwrap()).unwrap();
        assert!(matches!(receive(&mut connection), Packet::Binary(_)));
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn incorrect_password_and_code_preserve_failure() {
        let (url, _, worker) = peer(false);
        assert!(authenticate(&url, "wrong-password", None).is_err());
        assert!(worker.join().unwrap().is_err());
        let (url, code, worker) = peer(true);
        let Authentication::CodeRequired(pending) =
            authenticate(&url, "test-secret-password", None).unwrap()
        else {
            panic!("2FA was bypassed");
        };
        let actual = code.recv().unwrap();
        let wrong = if actual == "000000" {
            "111111"
        } else {
            "000000"
        };
        assert_eq!(
            pending.submit(wrong).err().unwrap().to_string(),
            "Invalid or expired Telegram code"
        );
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn an_observer_sees_no_session_content() {
        let (from_client, received) = mpsc::channel();
        let (address, _, worker) = serve(false, move |socket, channel| {
            socket.send(Message::Binary(
                channel.seal(auth::Kind::Binary, b"server-secret-output").unwrap().into(),
            ))?;
            let (_, bytes) = channel
                .open(&socket.read()?.into_data())
                .map_err(anyhow::Error::msg)?;
            from_client.send(bytes)?;
            Ok(())
        });
        let (url, captured) = wiretap(address);
        let mut connection = connect_test(&url);
        assert!(matches!(receive(&mut connection), Packet::Binary(bytes) if bytes == b"server-secret-output"));
        connection
            .send(Packet::Binary(b"client-secret-keystrokes".to_vec()))
            .unwrap();
        connection.flush().unwrap();
        assert_eq!(
            received.recv_timeout(Duration::from_secs(5)).unwrap(),
            b"client-secret-keystrokes"
        );
        worker.join().unwrap().unwrap();
        let sent = payloads(&captured[0].lock().unwrap());
        let received = payloads(&captured[1].lock().unwrap());
        let seen = |stream: &[u8], needle: &[u8]| stream.windows(needle.len()).any(|w| w == needle);
        assert!(seen(&sent, b"auth_start"), "The wiretap reads the login request");
        assert!(seen(&received, b"auth_challenge"), "The wiretap reads the challenge");
        for secret in [&b"client-secret-keystrokes"[..], b"test-secret-password"] {
            assert!(!seen(&sent, secret), "{} leaked", String::from_utf8_lossy(secret));
        }
        for secret in [&b"server-secret-output"[..], b"ready"] {
            assert!(!seen(&received, secret), "{} leaked", String::from_utf8_lossy(secret));
        }
    }

    #[test]
    fn injected_and_replayed_records_end_the_connection() {
        type Attack = fn(&mut Server, &mut auth::Channel) -> Result<()>;
        let attacks: [Attack; 3] = [
            |socket, _| {
                socket.send(Message::Text(r#"{"type":"topology","panes":[]}"#.into()))?;
                Ok(())
            },
            |socket, _| {
                socket.send(Message::Binary(vec![7; 300].into()))?;
                Ok(())
            },
            |socket, channel| {
                let record = channel.seal(auth::Kind::Binary, &[1]).map_err(anyhow::Error::msg)?;
                socket.send(Message::Binary(record.clone().into()))?;
                socket.send(Message::Binary(record.into()))?;
                Ok(())
            },
        ];
        for (index, attack) in attacks.into_iter().enumerate() {
            let (address, _, worker) = serve(false, attack);
            let mut connection = connect_test(&format!("ws://{address}"));
            if index == 2 {
                assert!(matches!(receive(&mut connection), Packet::Binary(bytes) if bytes == [1]));
            }
            let deadline = Instant::now() + Duration::from_secs(3);
            let error = loop {
                match connection.read() {
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                        thread::sleep(Duration::from_millis(1))
                    }
                    Err(e) => break e,
                    Ok(_) => panic!("attack {index}: accepted a forged packet"),
                }
            };
            assert_eq!(error.kind(), io::ErrorKind::InvalidData, "attack {index}: {error}");
            assert!(connection.send(Packet::Text(b"{}".to_vec())).is_err(), "attack {index} left the channel open");
            worker.join().unwrap().unwrap();
        }
    }

    #[test]
    fn saved_connections_contain_only_reconnect_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("connections.json");
        let saved = vec![SavedConnection {
            name: "Home".into(),
            alias: "home".into(),
            url: "wss://example.test/graffitty".into(),
            hostname: "build".into(),
            platform: "linux".into(),
            username: "developer".into(),
            remember: false,
            chromium_stream: StreamQuality { max_height: 2160, fps: 30, bitrate_kbps: 0 },
        }];
        save_connections(&path, &saved).unwrap();
        assert_eq!(load_connections(&path).unwrap(), saved);
        let value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(value[0].as_object().unwrap().len(), 8);
        // A connection saved before choosing stream limits streams with Auto.
        fs::write(&path, br#"[{"name":"Home","url":"wss://example.test/graffitty"}]"#).unwrap();
        assert_eq!(load_connections(&path).unwrap()[0].chromium_stream, StreamQuality::default());
        fs::write(&path, br#"[{"name":"Home","url":"wss://example.test/graffitty","chromium_stream":{"max_height":4320,"fps":0,"bitrate_kbps":0}}]"#).unwrap();
        assert!(load_connections(&path).is_err());
        assert!(validated_request("ws://user:password@example.test").is_err());
        assert!(validated_request("https://example.test").is_err());
    }

    #[test]
    fn aliases_are_server_scoped_and_independent_of_labels() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("connections.json");
        let entry = |url: &str, alias: &str| serde_json::from_value::<SavedConnection>(json!({
            "name":"Same display label", "alias":alias, "url":url
        })).unwrap();
        let a = entry("wss://a.test", "build");
        save_connections(&path, &[a.clone()]).unwrap();
        let before = fs::read(&path).unwrap();
        assert!(upsert_connection(&path, entry("wss://b.test", "build")).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        let mut renamed = a;
        renamed.alias = "worker".into();
        upsert_connection(&path, renamed).unwrap();
        assert!(load_connections(&path).unwrap().iter().all(|c| c.alias == "worker"));
        for invalid in ["../build", "host:7183", "a b", "/build"] {
            assert!(upsert_connection(&path, entry("wss://b.test", invalid)).is_err());
        }
    }

    #[test]
    fn hostname_defaults_are_unique_persistent_and_overridable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("connections.json");
        let entry = |url: &str, hostname: &str| serde_json::from_value::<SavedConnection>(json!({
            "name":"Display label", "url":url, "hostname":hostname
        })).unwrap();
        // An unverified endpoint has no hostname to choose from yet.
        assert!(upsert_connection(&path, entry("wss://a.test", "")).unwrap().alias.is_empty());
        let mut first = upsert_connection(&path, entry("wss://a.test", "Build Host")).unwrap();
        assert_eq!(first.alias, "build-host");
        assert_eq!(upsert_connection(&path, entry("wss://b.test", "Build Host")).unwrap().alias, "build-host-2");
        let renamed_host = entry("wss://a.test", "New Hostname");
        assert_eq!(upsert_connection(&path, renamed_host).unwrap().alias, "build-host");
        first.alias = "custom".into();
        upsert_connection(&path, first).unwrap();
        assert_eq!(upsert_connection(&path, entry("wss://a.test", "New Hostname")).unwrap().alias, "custom");
        assert!(load_connections(&path).unwrap().iter().filter(|e| e.url == "wss://a.test").all(|e| e.alias == "custom"));
        let mut entries = load_connections(&path).unwrap();
        let mut bare = entry("ws://c.test", "Build Host");
        bare.alias = "reserved".into();
        entries.push(bare);
        save_connections(&path, &entries).unwrap();
        assert_eq!(upsert_connection(&path, entry("ws://c.test:7183", "Build Host")).unwrap().alias, "reserved");
    }

    #[test]
    fn hostname_defaults_are_valid_even_for_non_hostname_display_metadata() {
        for (hostname, expected) in [("Build.Example", "build.example"), ("../Build Host!", "build-host"), ("개발🙂", "server")] {
            let alias = hostname_alias(hostname, |_| false);
            assert_eq!(alias, expected);
            assert!(graffitty_protocol::controller::valid_alias(&alias));
        }
        let hostname = "a".repeat(255);
        let first = hostname_alias(&hostname, |_| false);
        let second = hostname_alias(&hostname, |alias| alias == first);
        assert_eq!(first.len(), 64);
        assert_eq!(second.len(), 64);
        assert!(second.ends_with("-2"));
    }

    #[test]
    fn concurrent_logins_reserve_different_hostname_aliases() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("connections.json");
        let barrier = std::sync::Barrier::new(4);
        thread::scope(|scope| {
            let jobs: Vec<_> = (0..4).map(|index| {
                let path = &path;
                let barrier = &barrier;
                scope.spawn(move || {
                    let entry = serde_json::from_value(json!({"name":"", "url":format!("wss://fixture-{index}.test"),
                        "hostname":"Build"})).unwrap();
                    barrier.wait();
                    upsert_connection(path, entry).unwrap().alias
                })
            }).collect();
            let aliases: std::collections::BTreeSet<_> = jobs.into_iter().map(|job| job.join().unwrap()).collect();
            assert_eq!(aliases, ["build", "build-2", "build-3", "build-4"].map(String::from).into());
        });
        assert_eq!(load_connections(&path).unwrap().len(), 4);
    }

    #[test]
    fn saved_connection_reordering_preserves_groups_and_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("connections.json");
        let entries: Vec<SavedConnection> = ["a", "b", "c"]
            .into_iter().map(|server| serde_json::from_value(json!({
                "name": server, "url": format!("wss://{server}.test"),
                "hostname": "host", "username": "developer", "remember": true,
                "chromium_stream": {"max_height": 1080, "fps": 30, "bitrate_kbps": 4000}
            })).unwrap()).collect();
        save_connections(&path, &entries).unwrap();
        reorder_connections(&path, "wss://a.test", "wss://c.test", false).unwrap();
        assert_eq!(load_connections(&path).unwrap(), vec![entries[1].clone(), entries[2].clone(), entries[0].clone()]);
        reorder_connections(&path, "wss://a.test", "wss://b.test", true).unwrap();
        assert_eq!(load_connections(&path).unwrap(), entries);
        let bytes = fs::read(&path).unwrap();
        reorder_connections(&path, "wss://a.test", "wss://a.test", true).unwrap();
        assert!(reorder_connections(&path, "wss://missing.test", "wss://a.test", true).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        fs::write(&path, b"broken JSON").unwrap();
        assert!(reorder_connections(&path, "wss://a.test", "wss://b.test", true).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"broken JSON");
    }

    #[test]
    fn saved_connections_reject_session_selection() {
        assert!(serde_json::from_value::<SavedConnection>(json!({
            "name":"Build", "url":"wss://example.test", "workspace":"$0"
        })).is_err());
    }

    #[test]
    fn saved_connection_updates_validate_without_overwriting_corrupt_state() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("connections.json");
        let mut saved: SavedConnection = serde_json::from_value(json!({
            "name": "Build", "url": "wss://example.test",
            "hostname": "build", "remember": false, "chromium_stream": {}
        })).unwrap();
        saved = upsert_connection(&path, saved).unwrap();
        saved.name = "Build renamed".into();
        upsert_connection(&path, saved.clone()).unwrap();
        assert_eq!(load_connections(&path).unwrap(), vec![saved.clone()]);
        saved.name = "invalid\nname".into();
        assert!(upsert_connection(&path, saved.clone()).is_err());
        assert_eq!(load_connections(&path).unwrap()[0].name, "Build renamed");
        saved.name = "Build renamed".into();
        for (field, invalid) in [("username", "bad\nname"), ("platform", "bad\nplatform")] {
            let mut metadata = serde_json::to_value(&saved).unwrap();
            metadata[field] = json!(invalid);
            assert!(upsert_connection(&path, serde_json::from_value(metadata).unwrap()).is_err());
        }
        let mut with_password = serde_json::to_value(&saved).unwrap();
        with_password["token"] = json!("must never be persisted");
        assert!(serde_json::from_value::<SavedConnection>(with_password).is_err());
        fs::write(&path, b"broken JSON").unwrap();
        assert!(upsert_connection(&path, saved).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"broken JSON");
    }
}
