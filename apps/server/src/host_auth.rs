//! Local host controls reload authentication without replacing session owners.
use crate::{Error, Server, auth};
use serde_json::{Value, json};

pub fn remote_access(server: &mut Server, enabled: bool, address: Option<&str>) -> Result<Value, Error> {
    let listener = if enabled {
        let configured = std::net::SocketAddr::new(server.settings.remote.bind_address.parse()?, server.settings.remote.port).to_string();
        let address = address.unwrap_or(&configured);
        let parsed: std::net::SocketAddr = address.parse()?;
        if server.remote_listener.as_ref().is_some_and(|listener| listener.local_addr().ok() == Some(parsed)) {
            return Ok(server.remote_descriptor());
        }
        Some(crate::network_listener(address)?)
    } else {
        if server.remote_listener.is_none() { return Ok(Value::Null); }
        None
    };
    // A new choice replaces whatever the configured address reported at startup.
    server.remote_error = None;
    let previous = std::mem::replace(&mut server.remote_listener, listener);
    server.network_generation += 1;
    if let Err(error) = server.publish_descriptor() {
        server.remote_listener = previous;
        server.network_generation -= 1;
        return Err(error);
    }
    server.pending_handshakes.revoke();
    Ok(server.remote_descriptor())
}

pub fn settings(server: &Server) -> Result<Value, Error> {
    let config = auth::Config::load(&server.auth_path)?;
    Ok(json!({
        "auth_path":std::path::absolute(&server.auth_path)?,
        "connection_file":std::path::absolute(&server.descriptor)?,
        "manual":config.password.is_some(),
        "mode":if config.password.is_some() {"manual"}else{"temporary"},
        "temporary_enabled":config.password.is_none(),
        "credential":config.telegram_credential.as_deref().unwrap_or("graffitty-2fa"),
        "temporary_password_length":config.temporary_password_length,
        "telegram_credential":config.telegram_credential,
        "chat_id":config.telegram_chat_id,
        "temporary_password":if config.password.is_some() {""}else{&server.remote_token},
        "remote":server.remote_descriptor(),
        "remote_error":server.remote_error
    }))
}

pub fn reload(server: &mut Server, rotate: bool) -> Result<Value, Error> {
    let config = auth::Config::load(&server.auth_path)?;
    let temporary = if config.password.is_some() {
        if rotate {
            return Err("Temporary passwords are disabled in manual mode".into());
        }
        String::new()
    } else if !rotate && server.remote_token.len() == config.temporary_password_length {
        server.remote_token.clone()
    } else {
        auth::temporary_password(config.temporary_password_length)?
    };
    // Construct everything before touching the running authenticator. Existing
    // remote connections are revoked by the ordinary network-generation check;
    // local frontends and every PTY remain attached to the same process.
    let authentication = auth::Server::new(config, &temporary)?;
    let previous_auth = std::mem::replace(&mut server.auth, authentication);
    let previous_token = std::mem::replace(&mut server.remote_token, temporary);
    server.network_generation += 1;
    if let Err(error) = server.publish_descriptor() {
        server.auth = previous_auth;
        server.remote_token = previous_token;
        server.network_generation -= 1;
        return Err(error);
    }
    server.pending_handshakes.revoke();
    settings(server)
}
