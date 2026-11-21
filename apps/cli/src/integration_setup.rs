//! One-time, per-provider-home integration setup. Never replace unrelated settings.
use crate::platform::OpenOptionsExt;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use crate::{agent_bridge::Result, integration::hooks, options::Integrate};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{IsTerminal, Write},
    path::Path,
};

fn owned(hook: &Value, provider: &str) -> bool {
    hook["command"].as_str().is_some_and(|s| {
        s.starts_with("gft internal agent-hook-integrate ")
            && s.ends_with(&format!(" --provider {provider}"))
    })
}
fn command(provider: &str, action: &str) -> String {
    // Resolve the current installation through PATH in every provider shell.
    format!("gft internal agent-hook-integrate {action} --provider {provider}")
}

pub fn install(args: Integrate) -> Result<()> {
    if args.status && (args.apply || args.remove) {
        return Err("--status cannot be combined with --apply or --remove".into());
    }
    if args.provider == "pi" { return crate::pi::install(args); }
    if args.provider == "opencode" { return crate::opencode::install(args); }
    let logical_home = crate::agent_bridge::provider_home(&args.provider);
    // Preview/status must not create the provider directory, a lock, or a backup.
    let home = resolved_path(&logical_home)?;
    let mut codex_sources = vec![home.join("config.toml")];
    if logical_home != home {
        codex_sources.push(logical_home.join("config.toml"));
    }
    let _lock = if args.apply {
        fs::create_dir_all(&home)?;
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(home.join(".graffitty-integration.lock"))?;
        lock.lock()?;
        Some(lock)
    } else {
        None
    };
    let path = resolved_path(&home.join(if args.provider == "claude" {
        "settings.json"
    } else {
        "config.toml"
    }))?;
    let original = match fs::read_to_string(&path) {
        Ok(s) => Some(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(e.into()),
    };
    let source = original
        .as_deref()
        .unwrap_or(if args.provider == "claude" { "{}" } else { "" });
    let before = parse_config(&args.provider, source)?;
    println!("Config: {}", path.display());
    if args.status {
        let ready = status(&args.provider, &before, &codex_sources);
        println!(
            "Backup: {} ({})",
            backup_path(&path).display(),
            if backup_path(&path).exists() {
                "exists"
            } else {
                "none"
            }
        );
        println!("Hook activation: only inside Graffitty terminals; restart agents after setup.");
        return if ready {
            Ok(())
        } else {
            Err(format!(
                "Preview setup with `gft integrate agent {}`; use --apply to install or repair",
                args.provider
            )
            .into())
        };
    }
    let updated = if args.provider == "claude" {
        claude(source, args.remove)?
    } else {
        codex(source, &codex_sources, args.remove)?
    };
    let after = parse_config(&args.provider, &updated)?;
    if args.provider == "claude" {
        if args.remove {
            println!("Removal preserves crossSessionInbound; it is a shared Claude setting.");
        } else {
            println!(
                "Claude crossSessionInbound=accept allows incoming peer messages for all sessions using this config, including outside Graffitty. Stricter project or managed settings may still block delivery."
            );
        }
    }
    if before == after {
        println!("No changes needed.");
        return Ok(());
    }
    println!(
        "{} {} integration settings (file formatting may also change):",
        if args.apply { "Applying" } else { "Preview:" },
        if args.remove {
            "removal of Graffitty"
        } else {
            "Graffitty"
        }
    );
    print_preview(&before, &after);
    if original.is_some() {
        println!("Original backup: {}", backup_path(&path).display());
    } else {
        println!("New config; no original file to back up.");
    }
    if !args.apply {
        println!(
            "No files changed. Apply with: gft integrate agent {}{} --apply",
            args.provider,
            if args.remove { " --remove" } else { "" }
        );
        return Ok(());
    }
    write_config(&path, original.as_deref(), &updated)?;
    println!(
        "{} Graffitty integration settings.",
        if args.remove { "Removed" } else { "Installed" }
    );
    if !args.remove {
        println!(
            "Run {} normally inside Graffitty. Restart existing agents to load hooks.",
            args.provider
        );
    }
    Ok(())
}

fn resolved_path(path: &Path) -> Result<std::path::PathBuf> {
    match fs::symlink_metadata(path) {
        // Not std's canonicalize: its Windows `\\?\` form would key a second, unused
        // copy of every Codex hook trust entry beside the path Codex uses.
        Ok(_) => Ok(dunce::canonicalize(path)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let parent = path.parent().ok_or("Provider directory has no parent")?;
            Ok(resolved_path(parent)?.join(path.file_name().ok_or("Invalid provider path")?))
        }
        Err(e) => Err(e.into()),
    }
}
fn backup_path(path: &Path) -> std::path::PathBuf {
    path.with_file_name(format!(
        "{}.graffitty-backup",
        path.file_name().unwrap().to_string_lossy()
    ))
}
fn parse_config(provider: &str, source: &str) -> Result<Value> {
    Ok(if provider == "claude" {
        serde_json::from_str(source)?
    } else {
        toml_edit::de::from_str(source)?
    })
}
// Collapse equal branches before diffing so unrelated settings never appear.
fn preview_values(before: &Value, after: &Value) -> (Value, Value) {
    if before == after {
        let hidden = json!("… unchanged");
        return (hidden.clone(), hidden);
    }
    let mut left = before.clone();
    let mut right = after.clone();
    match (&mut left, &mut right) {
        (Value::Object(a), Value::Object(b)) => {
            for (key, value) in a.iter_mut() {
                if let Some(other) = b.get_mut(key) {
                    (*value, *other) = preview_values(value, other);
                }
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            for (value, other) in a.iter_mut().zip(b.iter_mut()) {
                (*value, *other) = preview_values(value, other);
            }
        }
        _ => {}
    }
    (left, right)
}

fn print_preview(before: &Value, after: &Value) {
    let color = std::io::stdout().is_terminal()
        && std::env::var_os("NO_COLOR").is_none()
        && std::env::var("TERM").as_deref() != Ok("dumb");
    let (before, after) = preview_values(before, after);
    let before = serde_json::to_string_pretty(&before).unwrap() + "\n";
    let after = serde_json::to_string_pretty(&after).unwrap() + "\n";
    let diff = similar::TextDiff::from_lines(&before, &after);
    let rendered = diff
        .unified_diff()
        .context_radius(3)
        .header("current", "proposed")
        .to_string();
    println!("\n  Configuration changes (− removed, + added; unchanged values collapsed)");
    for line in rendered.lines() {
        if color {
            let code = match line.as_bytes().first() {
                Some(b'+') => "32",
                Some(b'-') => "31",
                Some(b'@') => "36",
                _ => "2",
            };
            println!("\x1b[{code}m{line}\x1b[0m");
        } else {
            println!("{line}");
        }
    }
    println!();
}
fn status(provider: &str, config: &Value, sources: &[std::path::PathBuf]) -> bool {
    let mut ready = 0;
    for (event, key, action) in hooks(provider) {
        let command = command(provider, action);
        let matches: Vec<_> = config["hooks"][event]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
            .flat_map(|(g, group)| {
                group["hooks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .enumerate()
                    .filter(move |(_, hook)| owned(hook, provider))
                    .map(move |(h, hook)| (g, h, group, hook))
            })
            .collect();
        let mut health = if matches.is_empty() {
            "missing"
        } else {
            "duplicate or modified"
        };
        if let [(g, h, group, hook)] = matches.as_slice() {
            let timeout = if provider == "codex" && event == "SessionEnd" {
                3
            } else {
                10
            };
            let expected =
                json!({"hooks":[{"type":"command","command":command,"timeout":timeout}]});
            if *group == &expected {
                health = "installed";
                if provider == "codex" {
                    let identity = json!({"event_name":key,"hooks":[{"async":false,"command":command,"timeout":timeout,"type":"command"}]});
                    let hash = format!(
                        "sha256:{}",
                        Sha256::digest(serde_json::to_vec(&identity).unwrap())
                            .iter()
                            .map(|byte| format!("{byte:02x}"))
                            .collect::<String>()
                    );
                    let state = &config["hooks"]["state"]
                        [format!("{}:{key}:{g}:{h}", sources[0].display())];
                    if state["enabled"] == false {
                        health = "disabled";
                    } else if state["trusted_hash"] != hash {
                        health = "untrusted or outdated";
                    }
                } else if config["disableAllHooks"] == true {
                    health = "disabled globally";
                }
                if health == "installed" {
                    ready += 1;
                }
            } else if hook["command"] != command {
                health = "outdated command";
            }
        }
        println!("  {event}: {health}");
    }
    println!(
        "{}: {ready}/{} hooks ready in this config.",
        if ready == hooks(provider).count() {
            "Installed"
        } else {
            "Not ready"
        },
        hooks(provider).count()
    );
    let messages_ready = if provider == "claude" {
        let accepted = config["crossSessionInbound"] == "accept";
        println!(
            "  crossSessionInbound: {} (all sessions using this config; stricter settings may override)",
            if accepted {
                "accept"
            } else {
                "not ready; requires accept"
            }
        );
        accepted
    } else {
        true
    };
    ready == hooks(provider).count() && messages_ready
}

fn claude(source: &str, remove: bool) -> Result<String> {
    let mut config: Value = serde_json::from_str(source)?;
    let object = config
        .as_object_mut()
        .ok_or("Claude settings must be an object")?;
    if !remove {
        object.insert("crossSessionInbound".into(), json!("accept"));
    }
    if !object.contains_key("hooks") {
        if remove {
            return Ok(source.into());
        }
        object.insert("hooks".into(), json!({}));
    }
    let hooks = object
        .get_mut("hooks")
        .unwrap()
        .as_object_mut()
        .ok_or("Claude hooks must be an object")?;
    for (event, _, action) in crate::integration::hooks("claude") {
        let command = command("claude", action);
        if !hooks.contains_key(event) {
            if remove {
                continue;
            }
            hooks.insert(event.into(), json!([]));
        }
        let groups = hooks
            .get_mut(event)
            .unwrap()
            .as_array_mut()
            .ok_or("Claude event hooks must be arrays")?;
        let mut retained = Vec::new();
        let mut installed = false;
        for mut group in std::mem::take(groups) {
            let handlers = group["hooks"]
                .as_array_mut()
                .ok_or("Claude hook group needs a hooks array")?;
            let contained_ours = handlers.iter().any(|h| owned(h, "claude"));
            handlers.retain(|h| !owned(h, "claude"));
            if contained_ours && !remove && !installed {
                retained.push(json!({"hooks":[{"type":"command","command":command,"timeout":10}]}));
                installed = true;
            }
            if !contained_ours || !handlers.is_empty() {
                retained.push(group);
            }
        }
        if !remove && !installed {
            retained.push(json!({"hooks":[{"type":"command","command":command,"timeout":10}]}));
        }
        *groups = retained;
        if groups.is_empty() {
            hooks.remove(event);
        }
    }
    Ok(serde_json::to_string_pretty(&config)? + "\n")
}

fn codex(
    source: &str,
    sources: &[std::path::PathBuf],
    remove: bool,
) -> Result<String> {
    let mut doc: toml_edit::DocumentMut = source.parse()?;
    let mut config: Value = toml_edit::de::from_str(source)?;
    if config.get("hooks").is_none() {
        if remove {
            return Ok(source.into());
        }
        config["hooks"] = json!({});
    }
    let hooks = config["hooks"]
        .as_object_mut()
        .ok_or("Codex hooks must be a table")?;
    if doc.get("hooks").is_none() {
        doc["hooks"] = toml_edit::Item::Table(toml_edit::Table::new());
    } else if let Some(toml_edit::Value::InlineTable(table)) = doc["hooks"].as_value() {
        doc["hooks"] = toml_edit::Item::Table(table.clone().into_table());
    }
    let mut state = hooks.get("state").cloned().unwrap_or(json!({}));
    let states = state
        .as_object_mut()
        .ok_or("Codex hook state must be a table")?;
    let mut changed = false;
    for (event, key, action) in crate::integration::hooks("codex") {
        let command = command("codex", action);
        if !hooks.contains_key(event) {
            if remove {
                continue;
            }
            hooks.insert(event.into(), json!([]));
        }
        let groups = hooks
            .get_mut(event)
            .unwrap()
            .as_array_mut()
            .ok_or("Codex event hooks must be arrays")?;
        let mut existing = None;
        for (g, group) in groups.iter().enumerate() {
            for (h, handler) in group["hooks"]
                .as_array()
                .ok_or("Codex hook group needs a hooks array")?
                .iter()
                .enumerate()
            {
                if owned(handler, "codex") {
                    if existing.replace((g, h)).is_some() {
                        return Err(
                            "Duplicate Graffitty hooks; remove duplicates before installing".into(),
                        );
                    }
                }
            }
        }
        if let Some((g, h)) = existing {
            // We own a whole group. Preserve indices of every unrelated hook/trust entry.
            if groups[g]["hooks"].as_array().unwrap().len() != 1 {
                return Err(
                    "Graffitty hook group contains other hooks; move them to their own group first"
                        .into(),
                );
            }
            for path in sources {
                states.remove(&format!("{}:{key}:{g}:{h}", path.display()));
            }
            if remove {
                groups[g]["hooks"] = json!([]);
            }
        } else if remove {
            continue;
        }
        if !remove {
            let g = existing.map(|(g, _)| g).unwrap_or(groups.len());
            let timeout = if event == "SessionEnd" { 3 } else { 10 };
            let handler = json!({"type":"command","command":command,"timeout":timeout});
            let group = json!({"hooks":[handler]});
            if g == groups.len() {
                groups.push(group);
            } else {
                groups[g] = group;
            }
            let identity = json!({"event_name":key,"hooks":[{"async":false,"command":command,"timeout":timeout,"type":"command"}]});
            let hash = format!(
                "sha256:{}",
                Sha256::digest(serde_json::to_vec(&identity)?)
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
            );
            for path in sources {
                states.insert(
                    format!("{}:{key}:{g}:0", path.display()),
                    json!({"trusted_hash":hash}),
                );
            }
        }
        let mut replacement = toml_edit::ArrayOfTables::new();
        for group in groups.iter() {
            replacement.push(toml_edit::ser::to_document(group)?.into_table());
        }
        doc["hooks"][event] = toml_edit::Item::ArrayOfTables(replacement);
        changed = true;
    }
    if changed {
        if doc["hooks"].get("state").is_none() {
            doc["hooks"]["state"] = toml_edit::Item::Table(toml_edit::Table::new());
        }
        // Update individual trust keys, retaining comments and settings elsewhere.
        let previous = config["hooks"]["state"].as_object();
        if let Some(previous) = previous {
            for key in previous.keys() {
                if !states.contains_key(key) {
                    if let Some(table) = doc["hooks"]["state"].as_table_like_mut() {
                        table.remove(key);
                    }
                }
            }
        }
        for (key, value) in states {
            if previous.and_then(|p| p.get(key)) != Some(value) {
                let mut replacement = toml_edit::ser::to_document(&json!({"entry":value}))?;
                doc["hooks"]["state"][key] = replacement.remove("entry").unwrap();
            }
        }
    }
    Ok(doc.to_string())
}

fn write_config(path: &Path, original: Option<&str>, updated: &str) -> Result<()> {
    let backup = backup_path(path);
    if let Some(original) = original {
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&backup)
        {
            Ok(mut f) => {
                f.write_all(original.as_bytes())?;
                f.sync_all()?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.into()),
        }
    }
    let temp = path.with_file_name(format!(".graffitty-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mode = fs::metadata(path)
            .map(|m| {
                #[cfg(unix)] { m.permissions().mode() & 0o777 }
                #[cfg(windows)] { let _ = m; 0o600 }
            })
            .unwrap_or(0o600);
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temp)?;
        file.write_all(updated.as_bytes())?;
        file.sync_all()?;
        if fs::read_to_string(path).ok().as_deref() != original {
            return Err("Provider config changed during installation; retry".into());
        }
        fs::rename(&temp, path)?;
        Ok(())
    })();
    let _ = fs::remove_file(&temp);
    result
}
