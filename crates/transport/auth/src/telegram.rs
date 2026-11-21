//! Telegram bot credentials remain in the OS credential store, not auth.json.
use super::{Result, Zeroizing};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct Credentials {
    pub token: Zeroizing<String>,
    pub chat: String,
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn entry(profile: &str) -> Result<keyring::Entry> {
    keyring::Entry::new("com.graffitty.remote.telegram", profile)
        .map_err(|_| "System credential store unavailable".into())
}

pub fn saved(profile: &str) -> Result<Option<Credentials>> {
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    {
        match entry(profile)?.get_password() {
            Ok(value) => serde_json::from_str(&Zeroizing::new(value))
                .map(Some)
                .map_err(|_| "Invalid saved Telegram credentials".into()),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err("Cannot unlock Telegram credentials".into()),
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = profile;
        Ok(None)
    }
}

pub fn save(profile: &str, token: &str, chat: &str) -> Result<()> {
    let token = if token.is_empty() {
        saved(profile)?.ok_or("Enter the Telegram bot token")?.token
    } else {
        Zeroizing::new(token.to_owned())
    };
    validate(&token, chat)?;
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    {
        let value = Zeroizing::new(
            serde_json::to_string(&Credentials {
                token,
                chat: chat.into(),
            })
            .map_err(|_| "Cannot encode Telegram credentials")?,
        );
        entry(profile)?
            .set_password(&value)
            .map_err(|_| "Cannot save Telegram credentials".into())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = (profile, token);
        Err("Configure Telegram on the host computer".into())
    }
}

fn validate(token: &str, chat: &str) -> Result<()> {
    let (id, secret) = token.split_once(':').ok_or("Invalid Telegram bot token")?;
    if id.is_empty()
        || !id.bytes().all(|c| c.is_ascii_digit())
        || secret.is_empty()
        || !secret
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
    {
        return Err("Invalid Telegram bot token".into());
    }
    if chat.parse::<i64>().is_err() {
        return Err("Enter a numeric Telegram chat ID".into());
    }
    Ok(())
}

pub fn resolve(credential: &str, chat: Option<&str>) -> Result<Credentials> {
    resolve_with(credential, chat, saved(credential), graffitty_secrets::lookup)
}
fn resolve_with(
    credential: &str, chat: Option<&str>, stored: Result<Option<Credentials>>,
    lookup: impl FnOnce(&str, Option<&str>) -> Result<Option<String>>,
) -> Result<Credentials> {
    if let Ok(Some(credentials)) = stored { return Ok(credentials); }
    let token = lookup("TELEGRAM_BOT_TOKEN", Some(credential))?
        .ok_or("Configure a Telegram bot credential")?;
    let chat = chat.map(str::to_owned)
        .or_else(|| std::env::var("TELEGRAM_CHAT_ID").ok())
        .ok_or("Configure the Telegram destination chat ID")?;
    validate(&token, &chat)?;
    Ok(Credentials { token: Zeroizing::new(token), chat })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saved_credentials_win_and_headless_sources_use_the_selected_name() {
        let stored = Credentials { token: Zeroizing::new("123:saved".into()), chat: "456".into() };
        let found = resolve_with("work", Some("789"), Ok(Some(stored)), |_, _| panic!("Saved credentials must win")).unwrap();
        assert_eq!(found.chat, "456");
        let found = resolve_with("work", Some("789"), Err("No system store".into()), |env, selected| {
            assert_eq!(env, "TELEGRAM_BOT_TOKEN");
            assert_eq!(selected, Some("work"));
            Ok(Some("123:command".into()))
        }).unwrap();
        assert_eq!(&*found.token, "123:command");
        assert_eq!(found.chat, "789");
        assert!(resolve_with("work", Some("789"), Ok(None), |_, _| Err("helper failed".into())).is_err());
        assert!(resolve_with("work", Some("invalid"), Ok(None), |_, _| Ok(Some("123:command".into()))).is_err());
    }
    #[test]
    fn validate_bot_credentials() {
        assert!(validate("123:abc_DEF-456", "-100123456").is_ok());
        assert!(validate("123:abc/other", "123").is_err());
        assert!(validate("123:abc", "").is_err());
        assert!(validate("", "123").is_err());
    }
}
