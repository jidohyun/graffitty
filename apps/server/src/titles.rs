//! Surface titles are owned by the persistent session, never by its current view.
use crate::{Error, Server};
use serde_json::{Value, json};
use std::path::Path;

/// Abbreviate directory fallbacks using the shell's home, not the viewing client's.
/// Only display text changes: the session's actual startup/cwd paths stay absolute.
pub fn directory_title(path: &Path, home: Option<&Path>) -> String {
    if let Some(home) = home.filter(|home| home.is_absolute())
        && let Ok(relative) = path.strip_prefix(home) {
        if relative.as_os_str().is_empty() {
            return "~".into();
        }
        let suffix = relative.to_string_lossy();
        #[cfg(windows)]
        let suffix = suffix.replace('\\', "/");
        return format!("~/{suffix}");
    }
    path.to_string_lossy().into_owned()
}

/// OSC 7 is presentation data and may describe a remote SSH directory. Do not
/// require a local host or an existing directory just to display its name.
pub fn reported_directory(report: &str) -> String {
    let Some(uri) = report.strip_prefix("file://") else { return report.into() };
    let Some(slash) = uri.find('/') else { return String::new() };
    let path = &uri.as_bytes()[slash..];
    let mut decoded = Vec::with_capacity(path.len());
    let mut i = 0;
    while i < path.len() {
        if path[i] == b'%' && i + 2 < path.len()
            && let (Some(a), Some(b)) = ((path[i + 1] as char).to_digit(16), (path[i + 2] as char).to_digit(16)) {
            decoded.push((a * 16 + b) as u8);
            i += 3;
        } else {
            decoded.push(path[i]);
            i += 1;
        }
    }
    let path = String::from_utf8_lossy(&decoded).into_owned();
    #[cfg(windows)]
    let path = if path.starts_with('/') && path.as_bytes().get(2) == Some(&b':') {
        path[1..].to_owned()
    } else { path };
    path
}

pub fn validate(value: &Value) -> Result<&str, Error> {
    let title = value.as_str().ok_or("Expected title")?;
    if title.chars().count() > 200 {
        return Err("A title is at most 200 characters".into());
    }
    Ok(title)
}
fn terminal_target(caller: u64, value: &Value) -> Result<(), Error> {
    if value.is_null() {
        return Ok(());
    }
    let target = value.as_str().ok_or("Expected terminal target")?;
    let id = graffitty_workspace_core::pane_id::parse(target).ok_or("Expected %N")?;
    if id != caller {
        return Err(crate::api::error("forbidden", "Terminal access is scoped to the calling terminal"));
    }
    Ok(())
}
fn owned(caller: u64, owner: u64, same_workspace: bool) -> Result<(), Error> {
    crate::api::chromium_owner(caller, owner, same_workspace)
}
pub fn set(server: &mut Server, caller: u64, method: &str, params: &Value) -> Result<Value, Error> {
    let title = validate(&params["title"])?;
    if method == "window.set_title" {
        terminal_target(caller, &params["target"])?;
        let session = server.sessions.get_mut(&caller).ok_or("Terminal closed")?;
        session.pinned_title = title.into();
        return Ok(
            json!({"window":format!("%{caller}"),"title":session.title(),"pinned":!title.is_empty()}),
        );
    }
    let id = params["chromium"]
        .as_str()
        .and_then(graffitty_workspace_core::pane_id::parse)
        .ok_or("Expected %N")?;
    let workspace = &server
        .sessions
        .get(&caller)
        .map(|s| s.workspace.clone())
        .or_else(|| server.chromiums.get(&caller).filter(|b| b.owner == caller).map(|b| b.workspace.clone()))
        .ok_or("Pane closed")?;
    let chromium = server.chromiums.get_mut(&id).ok_or("Chromium closed")?;
    owned(caller, chromium.owner, chromium.workspace == *workspace)?;
    chromium.pinned_title = title.into();
    Ok(
        json!({"chromium":format!("%{id}"),"title":chromium.title(),"pinned":!title.is_empty()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn displayed_directory_decodes_remote_uri_without_local_filesystem_checks() {
        assert_eq!(reported_directory("file://remote.invalid/tmp/title%20%ED%95%9C%EA%B8%80"), "/tmp/title 한글");
        assert_eq!(reported_directory("file:///tmp/a%25+b%23c"), "/tmp/a%+b#c");
        assert_eq!(reported_directory("/tmp/literal%20name"), "/tmp/literal%20name");
        assert_eq!(reported_directory("file://host"), "");
        assert_eq!(reported_directory("file://host/tmp/%zz%"), "/tmp/%zz%");
    }
    #[test]
    fn directory_titles_abbreviate_only_complete_home_path_components() {
        let home = if cfg!(windows) { Path::new("C:/Users/demo") } else { Path::new("/home/demo") };
        assert_eq!(directory_title(home, Some(home)), "~");
        assert_eq!(directory_title(&home.join("projects/한글"), Some(home)), "~/projects/한글");
        let sibling = home.with_file_name("demo-other");
        assert_eq!(directory_title(&sibling, Some(home)), sibling.to_string_lossy());
        assert_eq!(directory_title(home, None), home.to_string_lossy());
        assert_eq!(directory_title(home, Some(Path::new(""))), home.to_string_lossy());
        assert_eq!(directory_title(home, Some(Path::new("relative"))), home.to_string_lossy());
    }
    #[test]
    fn title_limit_counts_unicode_characters_and_empty_clears_pin() {
        assert_eq!(validate(&json!("")).unwrap(), "");
        assert!(validate(&json!("한".repeat(200))).is_ok());
        assert!(validate(&json!("한".repeat(201))).is_err());
        assert!(validate(&json!(null)).is_err());
    }
    #[test]
    fn surface_pin_does_not_grant_another_terminal_or_workspace_access() {
        assert!(terminal_target(7, &Value::Null).is_ok());
        assert!(terminal_target(7, &json!("%7")).is_ok());
        assert!(terminal_target(0, &json!("%0")).is_ok());
        assert!(terminal_target(7, &json!("%07")).is_err());
        assert_eq!(crate::error_details(&terminal_target(7, &json!("%8")).unwrap_err())["code"], "forbidden");
        assert!(terminal_target(7, &json!("7")).is_err());
        assert!(owned(7, 7, true).is_ok());
        assert!(owned(7, 8, true).is_err());
        assert!(owned(7, 7, false).is_err());
    }
}
