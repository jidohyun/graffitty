use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use graffitty_remote_auth as auth;
use serde_json::{Value, json};
use std::{collections::HashMap, path::Path};

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct RemoteAuth {
    base: Base<RefCounted>,
    server: Option<auth::Server>,
    sessions: HashMap<i64, auth::wire::Session>,
    client: Option<auth::Client>,
    key: Option<auth::Key>,
}
#[godot_api]
impl IRefCounted for RemoteAuth {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            server: None,
            sessions: HashMap::new(),
            client: None,
            key: None,
        }
    }
}
fn reply(result: auth::Result<Value>) -> GString {
    GString::from(
        &match result {
            Ok(v) => v,
            Err(e) => json!({"error":e}),
        }
        .to_string(),
    )
}
#[godot_api]
impl RemoteAuth {
    #[func]
    fn normalize_server_url(&self, address: GString) -> GString {
        reply(graffitty_client_core::transport::normalize_server_url(&address.to_string())
            .map(|url| json!({"url": url})).map_err(|error| error.to_string()))
    }

    #[func]
    fn saved_connections(&self, path: GString) -> GString {
        reply(graffitty_client_core::transport::load_connections(Path::new(&path.to_string()))
            .map(|entries| json!({"connections": entries})).map_err(|e| e.to_string()))
    }

    #[func]
    fn save_connection(&self, path: GString, settings: VarDictionary) -> GString {
        reply((|| {
            // Godot's JSON reader uses floats even for saved integer limits.
            // Adapt UI values once; fractions and out-of-range values still fail
            // the typed schema instead of being truncated or accepted on disk.
            let value = crate::graph_client::from_variant(&settings.to_variant())?;
            let entry = serde_json::from_value::<graffitty_client_core::transport::SavedConnection>(value).map_err(|e| e.to_string())?;
            let entry = graffitty_client_core::transport::upsert_connection(Path::new(&path.to_string()), entry).map_err(|e| e.to_string())?;
            Ok(json!({"ok": true, "connection": entry}))
        })())
    }

    #[func]
    fn save_connections(&self, path: GString, settings: VarArray) -> GString {
        reply((|| {
            let value = crate::graph_client::from_variant(&settings.to_variant())?;
            let entries = serde_json::from_value::<Vec<graffitty_client_core::transport::SavedConnection>>(value).map_err(|e| e.to_string())?;
            graffitty_client_core::transport::save_connections(Path::new(&path.to_string()), &entries).map_err(|e| e.to_string())?;
            Ok(json!({"ok": true}))
        })())
    }

    #[func]
    fn reorder_connections(&self, path: GString, source: GString, target: GString, before: bool) -> GString {
        reply(graffitty_client_core::transport::reorder_connections(
            Path::new(&path.to_string()), &source.to_string(), &target.to_string(), before,
        ).map(|()| json!({"ok": true})).map_err(|error| error.to_string()))
    }

    #[func]
    fn configure(&mut self, path: GString, temporary: GString) -> GString {
        self.server = None;
        self.sessions.clear();
        reply((|| {
            let config = auth::Config::load(Path::new(&path.to_string()))?;
            let permanent = config.password.is_some();
            let temporary = if permanent {
                String::new()
            } else if temporary.is_empty() {
                auth::temporary_password(config.temporary_password_length)?
            } else {
                temporary.to_string()
            };
            self.server = Some(auth::Server::new(config, &temporary)?);
            Ok(json!({"permanent":permanent,"temporary_password":temporary}))
        })())
    }
    #[func]
    fn settings(&self, path: GString) -> GString {
        reply(auth::Config::load(Path::new(&path.to_string())).map(
            |c| json!({"permanent":c.password.is_some(),"telegram_credential":c.telegram_credential,"chat_id":c.telegram_chat_id,"temporary_password_length":c.temporary_password_length}),
        ))
    }
    #[func]
    fn save_settings(
        &self,
        path: GString,
        password: GString,
        clear: bool,
        telegram_credential: GString,
        telegram_chat_id: GString,
        temporary_password_length: i64,
    ) -> GString {
        reply((|| {
            let path = path.to_string();
            let path = Path::new(&path);
            let mut config = auth::Config::load(path)?;
            if ![6, 8, 10].contains(&temporary_password_length) {
                return Err("Temporary password length must be 6, 8, or 10".into());
            }
            config.temporary_password_length = temporary_password_length as usize;
            if clear {
                config.password = None;
            }
            if !password.is_empty() {
                config.set_password(&password.to_string())?;
            }
            if !telegram_chat_id.is_empty() && telegram_chat_id.to_string().parse::<i64>().is_err() {
                return Err("Enter a numeric Telegram chat ID".into());
            }
            if !telegram_credential.is_empty() && !graffitty_remote_auth::valid_credential_name(&telegram_credential.to_string()) {
                return Err("Invalid Telegram credential name".into());
            }
            config.telegram_chat_id = (!telegram_chat_id.is_empty()).then(|| telegram_chat_id.to_string());
            config.telegram_credential = if telegram_credential.is_empty() {
                None
            } else {
                Some(telegram_credential.to_string())
            };
            config.save(path)?;
            Ok(json!({"ok":true}))
        })())
    }
    #[func]
    fn telegram_settings(&self, profile: GString) -> GString {
        reply(auth::telegram::saved(&profile.to_string()).map(|saved| {
            json!({"saved":saved.is_some(),"chat_id":saved.map(|c|c.chat).unwrap_or_default()})
        }))
    }
    #[func]
    fn save_telegram_credentials(
        &self,
        profile: GString,
        token: GString,
        chat: GString,
    ) -> GString {
        reply(
            auth::telegram::save(&profile.to_string(), &token.to_string(), &chat.to_string())
                .map(|_| json!({"ok":true})),
        )
    }
    #[func]
    fn server_step(&mut self, id: i64, message: GString) -> GString {
        reply((|| {
            if !self.sessions.contains_key(&id) && self.sessions.len() >= 32 {
                return Err("Too many clients".into());
            }
            let value: Value = serde_json::from_str(&message.to_string())
                .map_err(|_| "Invalid authentication message")?;
            self.sessions.entry(id).or_default().step(
                self.server.as_mut().ok_or("Authentication unavailable")?,
                &value,
            )
        })())
    }
    #[func]
    fn server_poll(&mut self, id: i64) -> GString {
        reply(
            self.sessions
                .get_mut(&id)
                .map(|s| s.poll().map(|v| v.unwrap_or(Value::Null)))
                .unwrap_or(Ok(Value::Null)),
        )
    }
    #[func]
    fn server_timeout(&self, id: i64) -> i64 {
        self.sessions
            .get(&id)
            .map(|s| s.timeout_seconds() as i64)
            .unwrap_or(10)
    }
    #[func]
    fn server_forget(&mut self, id: i64) {
        self.sessions.remove(&id);
    }
    #[func]
    fn client_start(&mut self, password: GString, context: GString) -> GString {
        self.client = None;
        self.key = None;
        reply((|| {
            let value: Value = serde_json::from_str(&context.to_string())
                .map_err(|_| "Invalid authentication context")?;
            let (client, message) =
                auth::Client::start(&password.to_string(), &auth::wire::context(&value)?)?;
            self.client = Some(client);
            Ok(json!({"message":message}))
        })())
    }
    #[func]
    fn client_finish(&mut self, message: GString) -> GString {
        reply((|| {
            let (key, message) = self
                .client
                .take()
                .ok_or("Unexpected authentication challenge")?
                .finish(&message.to_string())?;
            self.key = Some(key);
            Ok(json!({"message":message}))
        })())
    }
    /// The verified login's encrypted channel; null before the password is
    /// verified. Install it on the WebSocket right after sending auth_finish.
    #[func]
    fn client_channel(&self) -> Option<Gd<SecureChannel>> {
        let channel = self.key.as_ref()?.channel(auth::Role::Client);
        Some(Gd::from_init_fn(|base| SecureChannel { base, channel }))
    }
    /// The verified login's video datagram link to the owner at `host`, an
    /// IP address, and `port`. Null before verification or without a socket.
    #[func]
    fn video_datagram_link(&self, host: GString, port: i64, ssrc: i64) -> Option<Gd<crate::video_datagram::VideoDatagramLink>> {
        let key = self.key.as_ref()?;
        let host: std::net::IpAddr = host.to_string().trim_matches(['[', ']']).parse().ok()?;
        let port = u16::try_from(port).ok().filter(|port| *port != 0)?;
        let ssrc = u32::try_from(ssrc).ok().filter(|ssrc| *ssrc != 0)?;
        crate::video_datagram::VideoDatagramLink::start(key.datagram(auth::Role::Client), host, port, ssrc)
            .map_err(|error| godot_warn!("Video datagrams unavailable: {error}"))
            .ok()
    }
    #[func]
    fn code_proof(&self, code: GString) -> GString {
        reply(
            self.key
                .as_ref()
                .ok_or("Password not verified".into())
                .map(|key| json!({"proof":key.code_proof(&code.to_string())})),
        )
    }
    /// No plaintext fallback when the system credential store is unavailable.
    #[func]
    fn credential(&self, operation: GString, account: GString, password: GString) -> GString {
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            reply((|| {
                let entry = keyring::Entry::new("com.graffitty.remote", &account.to_string())
                    .map_err(|_| "System credential store unavailable")?;
                match operation.to_string().as_str() {
                    "get" => match entry.get_password() {
                        Ok(p) => Ok(json!({"password":p})),
                        Err(keyring::Error::NoEntry) => Ok(json!({"password":""})),
                        Err(_) => Err("Cannot unlock saved password".into()),
                    },
                    "set" => {
                        entry
                            .set_password(&password.to_string())
                            .map_err(|_| "Cannot save password in system credential store")?;
                        Ok(json!({"ok":true}))
                    }
                    "delete" => {
                        match entry.delete_credential() {
                            Ok(()) | Err(keyring::Error::NoEntry) => (),
                            Err(_) => return Err("Cannot delete saved password".into()),
                        };
                        Ok(json!({"ok":true}))
                    }
                    _ => Err("Unknown credential operation".into()),
                }
            })())
        }
        #[cfg(target_os = "ios")]
        {
            use security_framework::passwords;
            const SERVICE: &str = "com.graffitty.remote";
            const NOT_FOUND: i32 = -25300; // errSecItemNotFound
            let account = account.to_string();
            reply((|| match operation.to_string().as_str() {
                "get" => match passwords::get_generic_password(SERVICE, &account) {
                    Ok(bytes) => String::from_utf8(bytes)
                        .map(|password| json!({"password": password}))
                        .map_err(|_| "Invalid saved password".into()),
                    Err(error) if error.code() == NOT_FOUND => Ok(json!({"password": ""})),
                    Err(_) => Err("Cannot unlock saved password".into()),
                },
                "set" => passwords::set_generic_password(SERVICE, &account, password.to_string().as_bytes())
                    .map(|()| json!({"ok": true}))
                    .map_err(|_| "Cannot save password in system credential store".into()),
                "delete" => match passwords::delete_generic_password(SERVICE, &account) {
                    Ok(()) => Ok(json!({"ok": true})),
                    Err(error) if error.code() == NOT_FOUND => Ok(json!({"ok": true})),
                    Err(_) => Err("Cannot delete saved password".into()),
                },
                _ => Err("Unknown credential operation".into()),
            })())
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux", target_os = "ios")))]
        {
            let _ = (operation, account, password);
            reply(Err("Use the platform credential bridge".into()))
        }
    }
}

/// One login's channel for a GDScript WebSocket. Records must be opened in
/// order; after any failure the channel refuses everything.
#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct SecureChannel {
    base: Base<RefCounted>,
    channel: auth::Channel,
}
#[godot_api]
impl SecureChannel {
    /// An empty result means the channel failed and the connection must close.
    #[func]
    fn seal(&mut self, payload: PackedByteArray, text: bool) -> PackedByteArray {
        let kind = if text { auth::Kind::Text } else { auth::Kind::Binary };
        self.channel
            .seal(kind, payload.as_slice())
            .map(|record| PackedByteArray::from(record.as_slice()))
            .unwrap_or_default()
    }
    /// `{text, data}` for a valid record, otherwise `{error}`.
    #[func]
    fn open(&mut self, record: PackedByteArray) -> VarDictionary {
        let mut result = VarDictionary::new();
        match self.channel.open(record.as_slice()) {
            Ok((kind, data)) => {
                result.set("text", kind == auth::Kind::Text);
                result.set("data", &PackedByteArray::from(data.as_slice()));
            }
            Err(error) => result.set("error", error.as_str()),
        }
        result
    }
}
