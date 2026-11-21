//! Credentials never enter config objects, UI fields, process arguments, or logs.
use crate::agent_bridge::Result;
use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    terminal,
};
use std::io::{self, IsTerminal, Write};

/// Explicit credentials are exclusive; defaults use environment then host bindings.
pub fn lookup(name: &str, credential: Option<&str>) -> Result<Option<String>> {
    graffitty_secrets::lookup(name, credential).map_err(Into::into)
}

pub fn named(name: &str, credential: Option<&str>, interactive: bool) -> Result<String> {
    if let Some(value) = lookup(name, credential)? { return Ok(value); }
    if !interactive || !io::stdin().is_terminal() {
        return Err(format!("Set {name} or select a credential in secrets.toml; hidden input requires an interactive stdin terminal").into());
    }
    terminal::enable_raw_mode()?;
    struct Restore;
    impl Drop for Restore {
        fn drop(&mut self) {
            let _ = terminal::disable_raw_mode();
            eprintln!();
        }
    }
    let _restore = Restore;
    eprint!("{name} (hidden): ");
    io::stderr().flush()?;
    let mut secret = String::new();
    loop {
        match event::read()? {
            Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Enter if !secret.trim().is_empty() => return Ok(secret),
                KeyCode::Enter => return Err(format!("{name} must not be empty").into()),
                KeyCode::Esc => return Err("Secret entry cancelled".into()),
                KeyCode::Char('c' | 'd') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    return Err("Secret entry cancelled".into());
                }
                KeyCode::Backspace => {
                    secret.pop();
                }
                KeyCode::Char(c)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    secret.push(c);
                }
                _ => {}
            },
            _ => {}
        }
    }
}

pub fn destination(name: &str, current: &str, interactive: bool) -> Result<String> {
    if !current.trim().is_empty() { return Ok(current.to_owned()); }
    if !interactive || !io::stdin().is_terminal() {
        return Err(format!("Set {name}, its CLI flag, or the destination in --config").into());
    }
    eprint!("{name}: ");
    io::stderr().flush()?;
    let mut value = String::new();
    io::stdin().read_line(&mut value)?;
    let value = value.trim().to_owned();
    if value.is_empty() {
        return Err(format!("{name} must not be empty").into());
    }
    Ok(value)
}
