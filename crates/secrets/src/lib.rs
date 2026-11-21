//! Host-owned credential sources. Values never enter configuration or the wire protocol.
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

mod process;
type Result<T> = std::result::Result<T, String>;
const MAX_SECRET_BYTES: usize = 64 * 1024;
static RESOLVER: OnceLock<Result<Mutex<Resolver>>> = OnceLock::new();

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct Config {
    defaults: BTreeMap<String, String>,
    secrets: BTreeMap<String, Source>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Source {
    env_var: Option<String>,
    command: Option<Vec<String>>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    cwd: Option<PathBuf>,
    #[serde(default = "timeout")]
    timeout_seconds: u64,
    #[serde(default = "cache_time")]
    cache_seconds: u64,
}
fn timeout() -> u64 {
    5
}
fn cache_time() -> u64 {
    300
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
}
fn valid_env(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 256
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}
fn valid_value(value: String) -> Result<String> {
    if value.len() > MAX_SECRET_BYTES || value.trim().is_empty() || value.contains('\0') {
        Err("Credential source returned an empty or invalid value".into())
    } else {
        Ok(value)
    }
}
fn environment(name: &str) -> Result<Option<String>> {
    match std::env::var(name) {
        Ok(value) if value.trim().is_empty() => Ok(None),
        Ok(value) => valid_value(value).map(Some),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(_) => Err("Credential environment variable is not UTF-8".into()),
    }
}

/// Explicit selection is exclusive. Otherwise the conventional environment
/// variable wins, followed by an explicitly configured default binding.
pub fn lookup(default_env: &str, credential: Option<&str>) -> Result<Option<String>> {
    if credential.is_none() {
        if let Some(value) = environment(default_env)? {
            return Ok(Some(value));
        }
    }
    let resolver = RESOLVER
        .get_or_init(|| {
            let (path, explicit) = config_path()?;
            Resolver::load(&path, explicit).map(Mutex::new)
        })
        .as_ref()
        .map_err(Clone::clone)?;
    let mut resolver = resolver
        .lock()
        .map_err(|_| "Credential resolver unavailable")?;
    let name = match credential {
        Some(name) => name.to_owned(),
        None => match resolver.config.defaults.get(default_env) {
            Some(name) => name.clone(),
            None => return Ok(None),
        },
    };
    resolver.resolve(&name).map(Some)
}

fn config_path() -> Result<(PathBuf, bool)> {
    if let Some(path) = std::env::var_os("GRAFFITTY_SECRETS_CONFIG") {
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err("GRAFFITTY_SECRETS_CONFIG must be an absolute path".into());
        }
        return Ok((path, true));
    }
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .or_else(|| std::env::var_os("USERPROFILE"))
                .map(|p| PathBuf::from(p).join(".config"))
        })
        .ok_or("Cannot locate host secrets.toml")?;
    if !root.is_absolute() {
        return Err("Host configuration directory must be absolute".into());
    }
    Ok((root.join("graffitty/secrets.toml"), false))
}

struct Resolver {
    config: Config,
    directory: PathBuf,
    cache: BTreeMap<String, (Instant, Zeroizing<String>)>,
}
impl Resolver {
    fn load(path: &Path, explicit: bool) -> Result<Self> {
        let config = match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str::<Config>(&text).map_err(|_| "Invalid secrets.toml: expected defaults and secret sources; unknown fields are rejected")?,
            Err(e) if !explicit && e.kind() == std::io::ErrorKind::NotFound => Config::default(),
            Err(_) => return Err("Cannot read host secrets.toml".into()),
        };
        for (name, source) in &config.secrets {
            let valid = valid_name(name)
                && source.env_var.is_some() != source.command.is_some()
                && source.env_var.as_ref().is_none_or(|v| valid_env(v))
                && (source.command.is_some() || source.env.is_empty() && source.cwd.is_none())
                && source.command.as_ref().is_none_or(|args| {
                    !args.is_empty()
                        && args.len() <= 64
                        && !args[0].is_empty()
                        && args
                            .iter()
                            .all(|arg| arg.len() <= 8192 && !arg.contains('\0'))
                        && (Path::new(&args[0]).is_absolute() || !args[0].contains(['/', '\\']))
                })
                && source
                    .env
                    .iter()
                    .all(|(k, v)| valid_env(k) && !v.contains('\0'))
                && source.cwd.as_ref().is_none_or(|p| p.is_absolute())
                && (1..=120).contains(&source.timeout_seconds)
                && source.cache_seconds <= 86400;
            if !valid {
                return Err("Invalid credential source: use exactly one env_var or command, valid environment names, absolute cwd, timeout 1–120 and cache 0–86400 seconds".into());
            }
        }
        if config
            .defaults
            .iter()
            .any(|(env, name)| !valid_env(env) || !config.secrets.contains_key(name))
        {
            return Err(
                "Invalid credential default: each environment name must reference a defined secret"
                    .into(),
            );
        }
        Ok(Self {
            config,
            directory: path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            cache: BTreeMap::new(),
        })
    }
    fn resolve(&mut self, name: &str) -> Result<String> {
        if !valid_name(name) {
            return Err("Invalid credential name".into());
        }
        let source = self
            .config
            .secrets
            .get(name)
            .ok_or_else(|| format!("Credential {name:?} is not defined in secrets.toml"))?;
        // Environment values are never cached; a source cannot override them.
        if let Some(env) = &source.env_var {
            return environment(env)?
                .ok_or_else(|| format!("Credential {name:?} requires environment variable {env}"));
        }
        if let Some((created, value)) = self.cache.get(name) {
            if created.elapsed() < Duration::from_secs(source.cache_seconds) {
                return Ok(value.to_string());
            }
        }
        self.cache.remove(name);
        let args = source.command.as_ref().expect("validated source");
        let value = process::read(
            args,
            &source.env,
            source.cwd.as_deref().unwrap_or(&self.directory),
            Duration::from_secs(source.timeout_seconds),
        )
        .and_then(valid_value)
        .map_err(|error| format!("Credential {name:?}: {error}"))?;
        if source.cache_seconds > 0 {
            self.cache.insert(
                name.to_owned(),
                (Instant::now(), Zeroizing::new(value.clone())),
            );
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests;
