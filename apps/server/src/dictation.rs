//! Live transcription and bounded audio uploads over authenticated workspace RPC.
//! Provider calls run off the session-owner thread; keys never enter replies.
mod live;
mod provider;
use crate::{Error, api};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

pub const MAX_AUDIO: usize = graffitty_dictation_audio::MAX_OPUS_BYTES;
const MAX_UPLOADS: usize = 8;
const MAX_WORKERS: usize = 2;
const DISABLED_MESSAGE: &str = "Microphone transcription is disabled on this server. On the server, edit ~/.config/graffitty/server.toml (or its --config file): set enabled = true under [dictation] and configure the provider API key. Then restart the server and try again. No API key is needed on this device.";
/// `provider = "auto"` uses the first of these whose key is available.
const AUTO: [&str; 3] = ["gemini", "openai", "openai-compatible"];

fn default_key(provider: &str) -> &str {
    match provider {
        "gemini" => "GRAFFITTY_GEMINI_API_KEY",
        "openai" => "GRAFFITTY_OPENAI_API_KEY",
        _ => "",
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Provider {
    pub credential: Option<String>,
    pub model: String,
    pub base_url: String,
}
impl Default for Provider {
    fn default() -> Self {
        Self {
            credential: None,
            model: String::new(),
            base_url: String::new(),
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub enabled: bool,
    pub provider: String,
    pub language: String,
    pub providers: BTreeMap<String, Provider>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: "auto".into(),
            language: String::new(),
            providers: [
                (
                    "openai",
                    "gpt-live-transcribe",
                    "https://api.openai.com/v1",
                ),
                (
                    "gemini",
                    "gemini-3.5-transcribe-live",
                    "https://generativelanguage.googleapis.com/v1beta",
                ),
            ]
            .into_iter()
            .map(|(id, model, base)| {
                (
                    id.into(),
                    Provider {
                        credential: None,
                        model: model.into(),
                        base_url: base.into(),
                    },
                )
            })
            .collect(),
        }
    }
}
impl Config {
    /// Providers to try in order: the named one, or every configured provider
    /// for auto, Gemini first.
    fn candidates(&self, name: &str) -> Vec<(String, Provider)> {
        let name = if name.is_empty() || name == "auto" { self.provider.as_str() } else { name };
        let names: Vec<&str> = if name == "auto" { AUTO.to_vec() } else { vec![name] };
        names
            .into_iter()
            .filter_map(|id| self.providers.get(id).map(|p| (id.to_owned(), p.clone())))
            .collect()
    }
    pub fn validate(&self) -> Result<(), String> {
        if !self.language.is_empty() {
            valid_text(&self.language, 32)?;
        }
        if self.provider != "auto" && !self.providers.contains_key(&self.provider) {
            return Err("dictation.provider must be auto or name a configured provider".into());
        }
        for (id, config) in &self.providers {
            if !["openai", "gemini", "openai-compatible"].contains(&id.as_str()) {
                return Err("Unsupported dictation provider".into());
            }
            if config.credential.as_ref().is_some_and(|name| !graffitty_secrets::valid_name(name))
                || id == "openai-compatible" && config.credential.is_none() {
                return Err("dictation credential must name a secret in secrets.toml; custom providers require it".into());
            }
            provider::valid_url(&config.base_url)?;
            valid_text(&config.model, 200)?;
        }
        Ok(())
    }
}
fn valid_text(text: &str, max: usize) -> Result<(), String> {
    if text.is_empty() || text.len() > max || text.chars().any(char::is_control) {
        Err("Invalid dictation model or language".into())
    } else {
        Ok(())
    }
}
struct Upload {
    owner: u64,
    candidates: Vec<(String, Provider)>,
    language: String,
    size: usize,
    audio: Vec<u8>,
    touched: Instant,
}
struct Work {
    owner: u64,
    canceled: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
}
pub struct Service {
    uploads: BTreeMap<String, Upload>,
    workers: BTreeMap<String, Work>,
    live: BTreeMap<String, live::Session>,
    /// Provider key lookup; tests replace it to stay off the user's credential sources.
    secret: fn(&str, Option<&str>) -> Result<Option<String>, String>,
}
impl Default for Service {
    fn default() -> Self {
        Self {
            uploads: BTreeMap::new(),
            workers: BTreeMap::new(),
            live: BTreeMap::new(),
            // Resolve on this host; clients never supply a source or receive keys.
            secret: graffitty_secrets::lookup,
        }
    }
}
impl Service {
    pub fn poll(&mut self) {
        self.live.retain(|_, session| !session.expired());
        self.uploads
            .retain(|_, upload| upload.touched.elapsed() < Duration::from_secs(30));
        self.workers
            .retain(|_, work| !work.done.load(Ordering::Acquire));
    }
    pub fn request(
        &mut self,
        config: &Config,
        owner: u64,
        method: &str,
        params: &Value,
        bytes: Option<&[u8]>,
    ) -> Result<api::Reply, Error> {
        self.poll();
        if method.starts_with("dictation.live.") {
            return self.live_request(config, owner, method, params, bytes);
        }
        let ready = |value| Ok(api::Reply::Ready(json!({"result":value})));
        if method == "dictation.settings" {
            if !config.enabled {
                // Disabled means no credential lookup, including credential helpers.
                return ready(json!({"enabled":false,"provider":config.provider,
                    "default":null,"providers":{},"message":DISABLED_MESSAGE,
                    "max_audio_bytes":MAX_AUDIO,"audio_format":"ogg-opus"}));
            }
            // Key lookups may run a credential helper, which can take seconds on a cold
            // lookup: answer from a bounded worker, never the owner thread.
            if self.workers.len() >= MAX_WORKERS {
                return Err(api::error("busy", "Dictation is busy; retry shortly"));
            }
            let (config, secret) = (config.clone(), self.secret);
            let done = Arc::new(AtomicBool::new(false));
            let (tx, rx) = mpsc::sync_channel(1);
            let done_worker = done.clone();
            std::thread::Builder::new()
                .name("dictation-settings".into())
                .spawn(move || {
                    let default = provider::select(&config.candidates("auto"), secret)
                        .ok()
                        .map(|(name, _, _)| name);
                    let providers: BTreeMap<_, _> = config
                        .providers
                        .iter()
                        .map(|(name, p)| {
                            let configured = secret(default_key(name), p.credential.as_deref()).is_ok_and(|value| value.is_some());
                            (name.clone(), json!({"model":p.model,"configured":configured}))
                        })
                        .collect();
                    let _ = tx.send(json!({"result":{"enabled":config.enabled,"provider":config.provider,
                        "default":default,"providers":providers,"max_audio_bytes":MAX_AUDIO,"audio_format":"ogg-opus"}}));
                    done_worker.store(true, Ordering::Release);
                })?;
            let canceled = Arc::new(AtomicBool::new(false));
            self.workers.insert(uuid::Uuid::new_v4().to_string(), Work { owner, canceled, done });
            return Ok(api::Reply::Pending(rx));
        }
        if !config.enabled {
            return Err(api::error(
                "dictation_disabled",
                DISABLED_MESSAGE,
            ));
        }
        if method == "dictation.begin" {
            if params["format"].as_str().unwrap_or("ogg-opus") != "ogg-opus" {
                return Err(api::error("dictation_format", "Expected Ogg Opus audio"));
            }
            if self.uploads.len() >= MAX_UPLOADS || self.workers.len() >= MAX_WORKERS {
                return Err(api::error("busy", "Dictation is busy; retry shortly"));
            }
            let mut candidates = config.candidates(params["provider"].as_str().unwrap_or(""));
            if candidates.is_empty() {
                return Err(api::error(
                    "dictation_provider",
                    "Provider is not configured on this server",
                ));
            }
            // A model only applies to an explicitly chosen provider.
            if let Some(model) = params["model"].as_str().filter(|s| !s.is_empty()) {
                if let [(_, selected)] = candidates.as_mut_slice() {
                    valid_text(model, 200)?;
                    selected.model = model.into();
                }
            }
            // Client URLs, key names and credentials are deliberately ignored.
            let language = params["language"].as_str().unwrap_or("");
            if !language.is_empty() {
                valid_text(language, 32)?;
            }
            let size = params["size"]
                .as_u64()
                .filter(|s| (44..=MAX_AUDIO as u64).contains(s))
                .ok_or_else(|| {
                    api::error("dictation_size", "Audio segment is too large or empty")
                })? as usize;
            let job = uuid::Uuid::new_v4().to_string();
            self.uploads.insert(
                job.clone(),
                Upload {
                    owner,
                    candidates,
                    language: language.into(),
                    size,
                    audio: Vec::with_capacity(size),
                    touched: Instant::now(),
                },
            );
            return ready(json!({"job":job}));
        }
        let job = params["job"].as_str().ok_or("Expected dictation job")?;
        if method == "dictation.cancel" {
            if self.live.get(job).is_some_and(|s| s.owner == owner) {
                self.live.remove(job);
            }
            if self.uploads.get(job).is_some_and(|u| u.owner == owner) {
                self.uploads.remove(job);
            }
            if let Some(work) = self.workers.get(job).filter(|w| w.owner == owner) {
                work.canceled.store(true, Ordering::Release);
            }
            return ready(json!({"canceled":true}));
        }
        let upload = self
            .uploads
            .get_mut(job)
            .filter(|u| u.owner == owner)
            .ok_or_else(|| {
                api::error(
                    "dictation_expired",
                    "Audio upload expired or belongs to another pane",
                )
            })?;
        if method == "dictation.append" {
            let bytes = bytes.ok_or("Expected binary audio packet")?;
            if params["offset"].as_u64() != Some(upload.audio.len() as u64)
                || bytes.len() > 65536
                || upload.audio.len() + bytes.len() > upload.size
            {
                return Err(api::error(
                    "dictation_upload",
                    "Audio upload is incomplete or out of order",
                ));
            }
            upload.audio.extend_from_slice(bytes);
            upload.touched = Instant::now();
            return ready(json!({"received":upload.audio.len()}));
        }
        if method != "dictation.transcribe" {
            return Err(api::error("unknown_method", "Unknown dictation method"));
        }
        if self.workers.len() >= MAX_WORKERS {
            return Err(api::error("busy", "Dictation is busy; retry shortly"));
        }
        if upload.audio.len() != upload.size {
            return Err(api::error("dictation_upload", "Audio upload is incomplete"));
        }
        let upload = self.uploads.remove(job).unwrap();
        let canceled = Arc::new(AtomicBool::new(false));
        let done = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::sync_channel(1);
        let cancel_worker = canceled.clone();
        let done_worker = done.clone();
        let secret = self.secret;
        std::thread::Builder::new()
            .name("dictation".into())
            .spawn(move || {
                // Validation and provider adaptation stay on the bounded worker.
                let result = (|| {
                    if cancel_worker.load(Ordering::Acquire) {
                        return Err("Dictation canceled".into());
                    }
                    let (name, config, key) = provider::select(&upload.candidates, secret)?;
                    provider::transcribe(
                        &name,
                        &config,
                        &key,
                        &upload.language,
                        &upload.audio,
                        &cancel_worker,
                    )
                })();
                let reply = if cancel_worker.load(Ordering::Acquire) {
                    json!({"error":{"code":"canceled","message":"Dictation canceled"}})
                } else {
                    match result {
                        Ok(text) => json!({"result":{"text":text}}),
                        Err(message) => {
                            json!({"error":{"code":"dictation_failed","message":message}})
                        }
                    }
                };
                let _ = tx.send(reply);
                done_worker.store(true, Ordering::Release);
            })?;
        self.workers.insert(
            job.into(),
            Work {
                owner,
                canceled,
                done,
            },
        );
        Ok(api::Reply::Pending(rx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn enabled_config() -> Config { Config { enabled: true, ..Config::default() } }
    fn result(reply: api::Reply) -> Value {
        match reply {
            api::Reply::Ready(value) => value["result"].clone(),
            _ => panic!("Expected immediate reply"),
        }
    }
    fn later(reply: api::Reply) -> Value {
        match reply {
            api::Reply::Pending(rx) => rx.recv_timeout(Duration::from_secs(5)).unwrap()["result"].clone(),
            _ => panic!("Expected a worker reply"),
        }
    }
    /// Only the Gemini key exists, from the configured source.
    fn gemini_only() -> Service {
        Service {
            secret: |name, _| Ok((name == "GRAFFITTY_GEMINI_API_KEY").then(|| "gemini-key".into())),
            ..Service::default()
        }
    }
    #[test]
    fn disabled_by_default_never_resolves_credentials_or_accepts_audio() {
        let config = Config::default();
        assert!(!config.enabled);
        let mut service = Service {
            secret: |_, _| panic!("Disabled dictation must not access credentials"),
            ..Service::default()
        };
        let settings = result(service.request(&config, 1, "dictation.settings", &json!({}), None).unwrap());
        assert_eq!(settings["enabled"], false);
        assert!(settings["message"].as_str().unwrap().contains("server.toml"));
        for method in ["dictation.begin", "dictation.append", "dictation.transcribe",
            "dictation.live.begin", "dictation.live.append", "dictation.live.finish", "dictation.live.poll"] {
            let error = match service.request(&config, 1, method,
                &json!({"enabled":true,"size":100,"format":"opus","sample_rate":48000}), Some(&[0, 0])) {
                Err(error) => error,
                Ok(_) => panic!("Disabled request succeeded: {method}"),
            };
            assert_eq!(api::error_details(&error)["code"], "dictation_disabled");
        }
        assert!(service.workers.is_empty() && service.live.is_empty() && service.uploads.is_empty());
    }
    #[test]
    fn settings_never_disclose_urls_key_names_or_keys() {
        let mut service = gemini_only();
        let value = later(
            service
                .request(
                    &enabled_config(),
                    1,
                    "dictation.settings",
                    &json!({}),
                    None,
                )
                .unwrap(),
        );
        assert_eq!(
            value["providers"]["gemini"]["model"],
            "gemini-3.5-transcribe-live"
        );
        assert!(!value.to_string().contains("GRAFFITTY_"));
        assert!(!value.to_string().contains("https://"));
        assert!(!value.to_string().contains("gemini-key"));
        assert_eq!(value["provider"], "auto");
        assert_eq!(value["default"], "gemini", "Auto uses the provider that has a key");
        assert_eq!(value["providers"]["gemini"]["configured"], true);
        assert_eq!(value["providers"]["openai"]["configured"], false);
    }
    #[test]
    fn auto_prefers_gemini_and_explicit_providers_keep_their_model() {
        let config = enabled_config();
        let names = |list: Vec<(String, Provider)>| list.into_iter().map(|(n, _)| n).collect::<Vec<_>>();
        assert_eq!(names(config.candidates("")), ["gemini", "openai"]);
        assert_eq!(names(config.candidates("auto")), ["gemini", "openai"]);
        assert_eq!(names(config.candidates("openai")), ["openai"]);
        let pinned = Config { provider: "openai".into(), ..enabled_config() };
        assert_eq!(names(pinned.candidates("auto")), ["openai"], "server.toml can pin a provider");
        let mut service = gemini_only();
        let begin = |service: &mut Service, provider: &str| {
            result(
                service
                    .request(&config, 1, "dictation.begin", &json!({"size":100,"provider":provider,"model":"custom-model"}), None)
                    .unwrap(),
            )["job"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let job = begin(&mut service, "openai");
        assert_eq!(service.uploads[&job].candidates[0].1.model, "custom-model");
        let job = begin(&mut service, "auto");
        assert!(
            service.uploads[&job].candidates.iter().all(|(_, p)| p.model != "custom-model"),
            "A model never applies across automatically chosen providers"
        );
    }
    #[test]
    fn keys_come_from_the_first_available_provider() {
        let config = enabled_config();
        let found = |key: &'static str| {
            provider::select(&config.candidates("auto"), move |name, _| Ok((name == key).then(|| "k".to_owned())))
                .map(|(name, _, _)| name)
        };
        assert_eq!(found("GRAFFITTY_GEMINI_API_KEY").unwrap(), "gemini");
        assert_eq!(found("GRAFFITTY_OPENAI_API_KEY").unwrap(), "openai");
        assert!(found("GRAFFITTY_OPENROUTER_API_KEY").is_err());
        let missing = found("UNRELATED").unwrap_err();
        assert!(missing.contains("GRAFFITTY_GEMINI_API_KEY") && missing.contains("secrets.toml"), "{missing}");
    }
    #[test]
    fn selected_source_is_exclusive_and_errors_stop_auto_selection() {
        let mut config = enabled_config();
        config.providers.get_mut("gemini").unwrap().credential = Some("microphone".into());
        let selected = provider::select(&config.candidates("auto"), |env, credential| {
            assert_eq!(env, "GRAFFITTY_GEMINI_API_KEY");
            assert_eq!(credential, Some("microphone"));
            Ok(Some("synthetic-key".into()))
        }).unwrap();
        assert_eq!(selected.0, "gemini");
        let error = provider::select(&config.candidates("auto"), |_, credential| {
            assert_eq!(credential, Some("microphone"));
            Err("source unavailable".into())
        }).unwrap_err();
        assert_eq!(error, "source unavailable");
        let mut service = Service {
            secret: |_, credential| Ok(credential.map(|_| "synthetic-key".into())),
            ..Service::default()
        };
        let value = later(service.request(&config, 1, "dictation.settings", &json!({}), None).unwrap());
        assert_eq!(value["providers"]["gemini"]["configured"], true);
        assert!(!value.to_string().contains("microphone"));
        assert!(!value.to_string().contains("synthetic-key"));
    }
    #[test]
    fn obsolete_dictation_source_field_is_rejected() {
        assert!(serde_json::from_value::<Provider>(json!({"key_env":"OLD_KEY"})).is_err());
    }
    #[test]
    fn audio_uploads_are_ordered_bounded_and_pane_scoped() {
        let mut service = gemini_only();
        let config = enabled_config();
        let begin = result(
            service
                .request(
                    &config,
                    42,
                    "dictation.begin",
                    &json!({"size":100,"base_url":"http://evil","credential":"ATTACKER"}),
                    None,
                )
                .unwrap(),
        );
        let job = begin["job"].as_str().unwrap();
        assert!(
            service.uploads[job].candidates.iter().all(|(_, p)| p.base_url.starts_with("https://")
                && p.credential.is_none()),
            "Client URLs and key names are ignored"
        );
        let append = json!({"job":job,"offset":0});
        assert!(
            service
                .request(&config, 43, "dictation.append", &append, Some(&[0; 60]))
                .is_err()
        );
        service
            .request(&config, 42, "dictation.append", &append, Some(&[0; 60]))
            .unwrap();
        assert!(
            service
                .request(&config, 42, "dictation.append", &append, Some(&[0; 60]))
                .is_err()
        );
        assert!(
            service
                .request(&config, 42, "dictation.transcribe", &begin, None)
                .is_err()
        );
        assert!(
            service
                .request(
                    &config,
                    42,
                    "dictation.append",
                    &json!({"job":job,"offset":60}),
                    Some(&[0; 41])
                )
                .is_err()
        );
        service
            .request(&config, 43, "dictation.cancel", &begin, None)
            .unwrap();
        assert!(service.uploads.contains_key(job));
        service
            .request(&config, 42, "dictation.cancel", &begin, None)
            .unwrap();
        assert!(service.uploads.is_empty());
        assert!(
            service
                .request(
                    &config,
                    42,
                    "dictation.begin",
                    &json!({"size":MAX_AUDIO+1}),
                    None
                )
                .is_err()
        );
    }
    #[test]
    fn abandoned_uploads_expire_and_canceled_workers_keep_their_slot() {
        let mut service = gemini_only();
        let config = enabled_config();
        for _ in 0..MAX_UPLOADS {
            service
                .request(&config, 1, "dictation.begin", &json!({"size":100}), None)
                .unwrap();
        }
        assert!(
            service
                .request(&config, 1, "dictation.begin", &json!({"size":100}), None)
                .is_err()
        );
        for upload in service.uploads.values_mut() {
            upload.touched -= Duration::from_secs(31);
        }
        service.poll();
        assert!(service.uploads.is_empty());
        for n in 0..MAX_WORKERS {
            service.workers.insert(
                n.to_string(),
                Work {
                    owner: 1,
                    canceled: Arc::new(AtomicBool::new(true)),
                    done: Arc::new(AtomicBool::new(false)),
                },
            );
        }
        assert!(
            service
                .request(&config, 1, "dictation.begin", &json!({"size":100}), None)
                .is_err()
        );
        for work in service.workers.values() {
            work.done.store(true, Ordering::Release);
        }
        service.poll();
        assert!(service.workers.is_empty());
    }

    #[test]
    fn malformed_compressed_audio_is_rejected_on_worker_before_provider_request() {
        let mut service = gemini_only();
        let config = enabled_config();
        assert!(
            service
                .request(
                    &config,
                    1,
                    "dictation.begin",
                    &json!({"size":100, "format":"wav"}),
                    None
                )
                .is_err()
        );
        let begin = result(
            service
                .request(
                    &config,
                    1,
                    "dictation.begin",
                    &json!({"size":100, "format":"ogg-opus"}),
                    None,
                )
                .unwrap(),
        );
        service
            .request(
                &config,
                1,
                "dictation.append",
                &json!({"job":begin["job"], "offset":0}),
                Some(&[0; 100]),
            )
            .unwrap();
        let api::Reply::Pending(rx) = service
            .request(&config, 1, "dictation.transcribe", &begin, None)
            .unwrap()
        else {
            panic!("Decoding must run off the session thread")
        };
        let reply = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(reply["error"]["code"], "dictation_failed");
        assert!(
            !reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("API_KEY")
        );
    }
}
