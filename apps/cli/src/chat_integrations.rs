//! External chat delivery. The graph transports content; this node owns rendering/uploads.
use crate::node_rpc as rpc;
use crate::{
    agent_bridge::Result,
    filter_node::{compile, evaluate},
    node_form::{Action, Form},
    options::Messaging,
};
use reqwest::blocking::{Client, multipart};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::IsTerminal,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const DEFAULT_TEMPLATE: &str =
    "{text: (.text // \"\"), content: (.content // []), renderings: (.renderings // {})}";
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Service {
    Telegram,
    Slack,
    Discord,
}
impl Service {
    fn name(self) -> &'static str {
        match self {
            Self::Telegram => "Telegram",
            Self::Slack => "Slack",
            Self::Discord => "Discord",
        }
    }
    fn token(self) -> &'static str {
        match self {
            Self::Telegram => "TELEGRAM_BOT_TOKEN",
            Self::Slack => "SLACK_BOT_TOKEN",
            Self::Discord => "DISCORD_BOT_TOKEN",
        }
    }
    fn destination_env(self) -> &'static str {
        match self {
            Self::Telegram => "TELEGRAM_CHAT_ID",
            Self::Slack => "SLACK_CHANNEL_ID",
            Self::Discord => "DISCORD_CHANNEL_ID",
        }
    }
    fn destination_key(self) -> &'static str {
        match self {
            Self::Telegram => "chat_id",
            Self::Slack | Self::Discord => "channel_id",
        }
    }
    fn icon(self) -> &'static str {
        match self {
            Self::Telegram => include_str!("../assets/icons/telegram.svg"),
            Self::Slack => include_str!("../assets/icons/slack.svg"),
            Self::Discord => include_str!("../assets/icons/discord.svg"),
        }
    }
    fn native(self) -> &'static str {
        match self {
            Self::Telegram => "telegram",
            Self::Slack => "slack",
            Self::Discord => "discord",
        }
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    #[serde(skip_serializing_if = "Option::is_none")]
    credential: Option<String>,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    chat_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    channel_id: Option<String>,
    message_template: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    message_template_file: Option<String>,
}
impl Settings {
    fn defaults(service: Service) -> Self {
        Self {
            credential: None,
            name: format!("{} Send", service.name()),
            chat_id: None,
            channel_id: None,
            message_template: DEFAULT_TEMPLATE.into(),
            message_template_file: None,
        }
    }
    fn destination(&self, service: Service) -> &str {
        match service {
            Service::Telegram => self.chat_id.as_deref(),
            Service::Slack | Service::Discord => self.channel_id.as_deref(),
        }
        .unwrap_or("")
    }
    fn set_destination(&mut self, service: Service, value: String) {
        match service {
            Service::Telegram => self.chat_id = Some(value),
            Service::Slack | Service::Discord => self.channel_id = Some(value),
        }
    }
    fn manifest(&self, service: Service) -> Value {
        json!({"name":self.name,"icon":{"svg":service.icon()},"inputs":[{"id":"in","name":format!("Send to {}",service.name()),"color":"#8ecaff"}],"outputs":[]})
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Message {
    #[serde(default)]
    text: String,
    #[serde(default)]
    content: Vec<Part>,
    #[serde(default)]
    renderings: HashMap<String, Value>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum Part {
    Text {
        text: String,
        #[serde(default = "plain")]
        format: String,
    },
    Image {
        path: String,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        alt: String,
        #[serde(default)]
        caption: String,
    },
    Audio {
        path: String,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        caption: String,
    },
    Video {
        path: String,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        caption: String,
    },
    File {
        path: String,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        caption: String,
    },
}
fn plain() -> String {
    "plain".into()
}
#[derive(Clone, Debug, Serialize, PartialEq)]
struct Upload {
    path: PathBuf,
    mime_type: String,
    field: String,
    alt: String,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
struct Operation {
    method: String,
    body: Value,
    upload: Option<Upload>,
}

fn load(service: Service, args: &Messaging) -> Result<(Settings, Option<PathBuf>)> {
    if args.edit && args.headless {
        return Err("Choose either --edit or --headless".into());
    }
    if args.message_template.is_some() && args.message_template_file.is_some() {
        return Err("Choose --message-template or --message-template-file".into());
    }
    if (service == Service::Telegram && args.channel_id.is_some())
        || (service != Service::Telegram && args.chat_id.is_some())
    {
        return Err("Choose the destination flag for this service".into());
    }
    let path = args
        .config
        .clone()
        .or_else(|| std::env::var("GRAFFITTY_NODE_CONFIG").ok())
        .map(PathBuf::from);
    let mut config = crate::node_config::load(
        serde_json::to_value(Settings::defaults(service))?,
        args.config.as_deref(),
    )?;
    if let Ok(value) = std::env::var(service.destination_env()) {
        if !value.trim().is_empty() {
            config[service.destination_key()] = json!(value);
        }
    }
    if let Some(credential) = &args.credential {
        config["credential"] = json!(credential);
    }
    if let Some(name) = &args.name {
        config["name"] = json!(name);
    }
    if let Some(value) = args.chat_id.as_ref().or(args.channel_id.as_ref()) {
        config[service.destination_key()] = json!(value);
    }
    if let Some(value) = &args.message_template {
        config["message_template"] = json!(value);
        config["message_template_file"] = Value::Null;
    }
    if let Some(value) = &args.message_template_file {
        config["message_template_file"] = json!(value);
    }
    let mut settings: Settings = serde_json::from_value(config).map_err(|_| "Invalid chat config: use only credential, name, chat_id/channel_id, message_template, message_template_file; secret values belong in environment variables or credential sources")?;
    if (service == Service::Telegram && settings.channel_id.is_some())
        || (service != Service::Telegram && settings.chat_id.is_some())
    {
        return Err("Configuration has a destination for the wrong service".into());
    }
    if let Some(file) = &settings.message_template_file {
        let file = if args.message_template_file.is_some() || Path::new(file).is_absolute() {
            PathBuf::from(file)
        } else {
            path.as_deref()
                .and_then(Path::parent)
                .unwrap_or(Path::new("."))
                .join(file)
        };
        settings.message_template = std::fs::read_to_string(&file)?;
        settings.message_template_file =
            Some(std::fs::canonicalize(file)?.to_string_lossy().into());
    }
    if !args.edit {
        validate_settings(&settings, service)?;
    }
    Ok((settings, path))
}
fn validate_settings(settings: &Settings, service: Service) -> Result<()> {
    if settings.name.trim().is_empty() || settings.name.chars().count() > 128 {
        return Err("Name must contain 1–128 characters".into());
    }
    if settings.destination(service).contains(['\n', '\r']) {
        return Err("Destination must be on one line".into());
    }
    if service == Service::Discord
        && !settings.destination(service).is_empty()
        && !settings
            .destination(service)
            .chars()
            .all(|c| c.is_ascii_digit())
    {
        return Err("Discord channel ID must contain digits only".into());
    }
    compile(&settings.message_template, "Message template")?;
    Ok(())
}
fn save(settings: &Settings, path: Option<&Path>) -> Result<String> {
    let path =
        path.ok_or("Choose --config PATH to save settings; no implicit config file is created")?;
    let mut value = serde_json::to_value(settings)?;
    if let Some(template) = &settings.message_template_file {
        atomic_write(Path::new(template), settings.message_template.as_bytes())?;
        value.as_object_mut().unwrap().remove("message_template");
    }
    atomic_write(
        path,
        (serde_json::to_string_pretty(&value)? + "\n").as_bytes(),
    )?;
    Ok(format!("Saved {} (credentials excluded)", path.display()))
}
fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    let temp = path.with_file_name(format!(
        ".{}.{}.tmp",
        path.file_name()
            .ok_or("Invalid save path")?
            .to_string_lossy(),
        uuid::Uuid::new_v4()
    ));
    let result = (|| {
        std::fs::write(&temp, data)?;
        std::fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
}
fn render(settings: &Settings, event: &Value) -> Result<Message> {
    let program = compile(&settings.message_template, "Message template")?;
    let value = evaluate(&program, event, "Message template", false)?
        .ok_or("Template must return a message")?;
    serde_json::from_value(value).map_err(|e| format!("Invalid common message: {e}").into())
}
fn text_operations(
    service: Service,
    text: &str,
    destination: &str,
    native: &Value,
) -> Vec<Operation> {
    let mut result = Vec::new();
    let limit = if service == Service::Discord {
        2000
    } else {
        4000
    };
    // Count UTF-16 units: conservative for Telegram's 4096 and Slack's text limits.
    let mut chunk = String::new();
    let mut units = 0;
    let chunks = text.chars().fold(Vec::new(), |mut chunks, c| {
        if units + c.len_utf16() > limit {
            chunks.push(std::mem::take(&mut chunk));
            units = 0;
        }
        chunk.push(c);
        units += c.len_utf16();
        chunks
    });
    let mut chunks = chunks;
    if !chunk.is_empty() {
        chunks.push(chunk);
    }
    for chunk in chunks {
        let body = if service == Service::Telegram {
            json!({"chat_id":destination,"text":chunk})
        } else if service == Service::Discord {
            json!({"content":chunk,"allowed_mentions":{"parse":[]}})
        } else {
            json!({"channel":destination,"text":chunk,"mrkdwn":false,"parse":"none","unfurl_links":false,"unfurl_media":false})
        };
        let mut body = body;
        if let Some(native) = native.as_object() {
            body.as_object_mut().unwrap().extend(native.clone());
        }
        result.push(Operation {
            method: match service {
                Service::Telegram => "sendMessage".into(),
                Service::Slack => "chat.postMessage".into(),
                Service::Discord => format!("channels/{destination}/messages"),
            },
            body,
            upload: None,
        });
    }
    result
}
fn plan(service: Service, settings: &Settings, message: &Message) -> Result<Vec<Operation>> {
    let destination = settings.destination(service);
    let native = message
        .renderings
        .get(service.native())
        .cloned()
        .unwrap_or(json!({}));
    let native = native
        .as_object()
        .ok_or("Native rendering must be an object")?;
    let allowed: &[&str] = if service == Service::Slack {
        &[
            "blocks",
            "mrkdwn",
            "thread_ts",
            "unfurl_links",
            "unfurl_media",
        ]
    } else if service == Service::Discord {
        &["embeds", "allowed_mentions", "message_reference", "flags"]
    } else {
        &["parse_mode", "disable_notification", "protect_content"]
    };
    if native.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err("Native rendering contains an unsupported field; destination and credentials are node settings".into());
    }
    if let Some(embeds) = native.get("embeds") {
        if !embeds.is_array()
            || embeds.as_array().unwrap().is_empty()
            || embeds.as_array().unwrap().len() > 10
        {
            return Err("Discord embeds must be an array of 1–10 embeds".into());
        }
        if message.text.trim().is_empty() || message.text.encode_utf16().count() > 2000 {
            return Err("Discord embeds require a text fallback of 1–2000 UTF-16 units".into());
        }
        return Ok(text_operations(
            service,
            &message.text,
            destination,
            &Value::Object(native.clone()),
        ));
    }
    if let Some(blocks) = native.get("blocks") {
        if !blocks.is_array()
            || blocks.as_array().unwrap().is_empty()
            || blocks.as_array().unwrap().len() > 50
        {
            return Err("Slack blocks must be an array of 1–50 blocks".into());
        }
        if message.text.trim().is_empty() || message.text.encode_utf16().count() > 4000 {
            return Err("Slack blocks require a plain-text fallback of 1–4000 UTF-16 units".into());
        }
        // A native representation replaces the common representation, never duplicates it.
        return Ok(text_operations(
            service,
            &message.text,
            destination,
            &Value::Object(native.clone()),
        ));
    }
    if native.contains_key("parse_mode") && !message.content.is_empty() {
        return Err(
            "Telegram parse_mode is for text-only native renderings; use plain text with media"
                .into(),
        );
    }
    if native.contains_key("parse_mode") && message.text.encode_utf16().count() > 4000 {
        return Err("Formatted Telegram text must fit one 4000-unit message".into());
    }
    let mut operations = Vec::new();
    let has_text = message
        .content
        .iter()
        .any(|p| matches!(p, Part::Text { .. }));
    if !has_text && !message.text.is_empty() {
        operations.extend(text_operations(
            service,
            &message.text,
            destination,
            &Value::Object(native.clone()),
        ));
    }
    for part in &message.content {
        let (path, mime, caption, field, alt) = match part {
            Part::Text { text, format } => {
                if format != "plain" {
                    return Err("Common text supports format: plain; use renderings for service-specific markup".into());
                }
                operations.extend(text_operations(
                    service,
                    text,
                    destination,
                    &Value::Object(native.clone()),
                ));
                continue;
            }
            Part::Image {
                path,
                mime_type,
                caption,
                alt,
            } => (path, mime_type, caption, "photo", alt.as_str()),
            Part::Audio {
                path,
                mime_type,
                caption,
            } => (path, mime_type, caption, "audio", ""),
            Part::Video {
                path,
                mime_type,
                caption,
            } => (path, mime_type, caption, "video", ""),
            Part::File {
                path,
                mime_type,
                caption,
            } => (path, mime_type, caption, "document", ""),
        };
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err("Attachment paths must be absolute local file paths".into());
        }
        let meta = std::fs::metadata(&path).map_err(|_| "Attachment file is unavailable")?;
        if !meta.is_file() || meta.len() == 0 {
            return Err("Attachment must be a nonempty regular file".into());
        }
        std::fs::File::open(&path).map_err(|_| "Attachment file is not readable")?;
        if service == Service::Telegram && caption.encode_utf16().count() > 1024 {
            return Err("Telegram captions must not exceed 1024 UTF-16 units".into());
        }
        let mime_type = mime
            .clone()
            .unwrap_or_else(|| "application/octet-stream".into());
        multipart::Part::bytes(Vec::new())
            .mime_str(&mime_type)
            .map_err(|_| "Invalid attachment MIME type")?;
        let mut body = if service == Service::Telegram {
            json!({"chat_id":destination,"caption":caption})
        } else if service == Service::Discord {
            if caption.encode_utf16().count() > 2000 {
                return Err("Discord captions must not exceed 2000 UTF-16 units".into());
            }
            json!({"content":caption,"allowed_mentions":{"parse":[]},"attachments":[{"id":0,"filename":path.file_name().unwrap().to_string_lossy(),"description":alt}]})
        } else {
            json!({"channel_id":destination,"initial_comment":caption})
        };
        for (key, value) in native {
            if (service == Service::Telegram && key != "parse_mode")
                || (service == Service::Slack && key == "thread_ts")
                || service == Service::Discord
            {
                body[key] = value.clone();
            }
        }
        operations.push(Operation {
            method: match (service, field) {
                (Service::Discord, _) => format!("channels/{destination}/messages"),
                (Service::Slack, _) => "files.upload".into(),
                (_, "photo") => "sendPhoto".into(),
                (_, "audio") => "sendAudio".into(),
                (_, "video") => "sendVideo".into(),
                _ => "sendDocument".into(),
            },
            body,
            upload: Some(Upload {
                path,
                mime_type,
                field: field.into(),
                alt: alt.into(),
            }),
        });
    }
    if operations.is_empty() {
        return Err("No message content; select text/content with a message template".into());
    }
    Ok(operations)
}

#[derive(Clone)]
struct Sender {
    service: Service,
    token: String,
    client: Client,
    base: String,
}
impl Sender {
    fn validate_token(service: Service, token: &str) -> Result<()> {
        if token.chars().any(char::is_whitespace)
            || (service == Service::Telegram
                && !token
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || ":_-".contains(c)))
        {
            return Err("Invalid bot token format".into());
        }
        Ok(())
    }
    fn new(service: Service, token: String) -> Result<Self> {
        Self::validate_token(service, &token)?;
        let client = Client::builder()
            .timeout(Duration::from_secs(90))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            service,
            token,
            client,
            base: if service == Service::Telegram {
                "https://api.telegram.org"
            } else if service == Service::Discord {
                "https://discord.com/api/v10"
            } else {
                "https://slack.com/api"
            }
            .into(),
        })
    }
    fn request(&self, method: &str) -> reqwest::blocking::RequestBuilder {
        if self.service == Service::Telegram {
            self.client
                .post(format!("{}/bot{}/{method}", self.base, self.token))
        } else if self.service == Service::Discord {
            self.client
                .post(format!("{}/{method}", self.base))
                .header("Authorization", format!("Bot {}", self.token))
        } else {
            self.client
                .post(format!("{}/{method}", self.base))
                .bearer_auth(&self.token)
        }
    }
    fn checked(&self, request: reqwest::blocking::RequestBuilder) -> Result<Value> {
        let response = request.send().map_err(
            |_| "Chat request failed; check connection and credentials (delivery may be uncertain)",
        )?;
        let status = response.status();
        if !status.is_success() {
            return Err(format!("{} returned HTTP {}; check credentials, destination, permissions, file limits, or rate limits", self.service.name(), status.as_u16()).into());
        }
        let body: Value = response
            .json()
            .map_err(|_| "Chat service returned invalid JSON")?;
        if self.service == Service::Discord {
            if body["id"].is_string() {
                return Ok(body);
            }
            return Err("Discord did not return a message ID".into());
        }
        if body["ok"] != true {
            let code = body["error"].as_str().unwrap_or("");
            let detail = match code {
                "invalid_auth" | "not_authed" | "token_revoked" | "token_expired" => {
                    "authentication failed"
                }
                "missing_scope" => "required bot scope is missing",
                "not_in_channel" | "channel_not_found" => {
                    "invite the bot to the configured channel"
                }
                "ratelimited" => "rate limited; retry later",
                _ => "request rejected; check permissions, destination and message format",
            };
            return Err(format!("{}: {detail}", self.service.name()).into());
        }
        Ok(body)
    }
    fn send(&self, operation: &Operation) -> Result<()> {
        if let Some(upload) = &operation.upload {
            if self.service == Service::Telegram || self.service == Service::Discord {
                let file = std::fs::File::open(&upload.path)
                    .map_err(|_| "Attachment is no longer readable")?;
                let part =
                    multipart::Part::reader_with_length(file.try_clone()?, file.metadata()?.len())
                        .file_name(
                            upload
                                .path
                                .file_name()
                                .unwrap()
                                .to_string_lossy()
                                .into_owned(),
                        )
                        .mime_str(&upload.mime_type)?;
                let mut form = if self.service == Service::Discord {
                    multipart::Form::new()
                        .part("files[0]", part)
                        .text("payload_json", operation.body.to_string())
                } else {
                    multipart::Form::new().part(upload.field.clone(), part)
                };
                if self.service == Service::Telegram {
                    for (key, value) in operation.body.as_object().unwrap() {
                        form = form.text(
                            key.clone(),
                            value
                                .as_str()
                                .map(str::to_owned)
                                .unwrap_or_else(|| value.to_string()),
                        );
                    }
                }
                self.checked(self.request(&operation.method).multipart(form))?;
            } else {
                let file = std::fs::File::open(&upload.path)
                    .map_err(|_| "Attachment is no longer readable")?;
                let name = upload.path.file_name().unwrap().to_string_lossy();
                let prepared = self.checked(self.request("files.getUploadURLExternal").form(&[
                    ("filename", name.as_ref()),
                    ("length", &file.metadata()?.len().to_string()),
                    ("alt_txt", &upload.alt),
                ]))?;
                let url = prepared["upload_url"]
                    .as_str()
                    .ok_or("Slack omitted upload URL")?;
                let parsed =
                    reqwest::Url::parse(url).map_err(|_| "Slack returned an invalid upload URL")?;
                let secure_upload = parsed.scheme() == "https";
                #[cfg(test)]
                let secure_upload = secure_upload
                    || (parsed.scheme() == "http" && parsed.host_str() == Some("127.0.0.1"));
                if !secure_upload {
                    return Err("Slack upload requires HTTPS".into());
                }
                let id = prepared["file_id"]
                    .as_str()
                    .ok_or("Slack omitted file ID")?;
                let response = self
                    .client
                    .post(url)
                    .header("Content-Type", &upload.mime_type)
                    .body(file)
                    .send()
                    .map_err(|_| "Slack file upload failed")?;
                if !response.status().is_success() {
                    return Err("Slack file upload was rejected".into());
                }
                let mut body = operation.body.clone();
                body["files"] = json!([{"id":id,"title":name}]);
                self.checked(self.request("files.completeUploadExternal").json(&body))?;
            }
        } else {
            self.checked(self.request(&operation.method).json(&operation.body))?;
        }
        Ok(())
    }
}

fn values(form: &Form, original: &Settings, service: Service) -> Settings {
    let values = form.values();
    let mut settings = original.clone();
    settings.name = values[0].clone();
    settings.set_destination(service, values[1].clone());
    settings.message_template = values[2].clone();
    settings
}
fn preview(service: Service, settings: &Settings, event: &Value) -> Result<String> {
    let message = render(settings, event)?;
    let operations = plan(service, settings, &message)?;
    Ok(serde_json::to_string_pretty(
        &json!({"message": message,"delivery":operations}),
    )?)
}

#[cfg(windows)]
fn timestamp() -> String {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut local: libc::tm = std::mem::zeroed();
        libc::localtime_s(&mut local, &now);
        format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}", local.tm_year + 1900, local.tm_mon + 1, local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec)
    }
}
#[cfg(unix)]
fn timestamp() -> String {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut local: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut local);
        let mut buffer = [0 as libc::c_char; 64];
        libc::strftime(
            buffer.as_mut_ptr(),
            buffer.len(),
            c"%Y-%m-%d %H:%M:%S %z".as_ptr(),
            &local,
        );
        std::ffi::CStr::from_ptr(buffer.as_ptr())
            .to_string_lossy()
            .into_owned()
    }
}
fn append_log(log: &mut Vec<String>, interactive: bool, message: &str) {
    let entry = format!("[{}] {}", timestamp(), message.replace('\x1b', "[ESC]"));
    if !interactive {
        eprintln!("{entry}");
    }
    log.push(entry);
    if log.len() > 200 {
        log.remove(0);
    }
}
fn sent_content(operation: &Operation) -> String {
    let mut text = operation
        .body
        .get("text")
        .or(operation.body.get("content"))
        .or(operation.body.get("caption"))
        .or(operation.body.get("initial_comment"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    for field in ["blocks", "embeds"] {
        if let Some(value) = operation.body.get(field) {
            text.push_str(&format!(
                "\n{field}: {}",
                serde_json::to_string_pretty(value).unwrap_or_default()
            ));
        }
    }
    if let Some(upload) = &operation.upload {
        text.push_str(&format!(
            "\n{}: {} ({})",
            upload.field,
            upload.path.display(),
            upload.mime_type
        ));
    }
    text
}
enum DeliveryUpdate {
    Sending(usize),
    Sent(usize),
    Finished,
    Failed(usize, String),
}

// Demo delivery deliberately owns neither an HTTP client nor credentials.
// Everything above the delivery boundary (form, validation, graph and log) is shared.
#[derive(Clone)]
enum Delivery {
    Live { sender: Sender, credential: Option<String>, refresh: bool },
    Demo,
}
impl Delivery {
    fn send(&self, operation: &Operation) -> Result<()> {
        self.send_with(operation, crate::secrets::lookup)
    }
    fn send_with(&self, operation: &Operation, lookup: impl FnOnce(&str, Option<&str>) -> Result<Option<String>>) -> Result<()> {
        match self {
            Self::Live { sender, credential, refresh } => {
                if !refresh { return sender.send(operation); }
                // Resolve on the delivery worker so expiring command credentials
                // obey the shared cache policy without blocking the node UI.
                let mut sender = sender.clone();
                sender.token = lookup(sender.service.token(), credential.as_deref())?
                    .ok_or("The node credential is no longer available")?;
                Sender::validate_token(sender.service, &sender.token)?;
                sender.send(operation)
            },
            Self::Demo => {
                std::thread::sleep(Duration::from_secs(3));
                Ok(())
            }
        }
    }
}

pub fn run(service: Service, args: Messaging) -> Result<()> {
    run_node(service, args, false)
}

pub fn run_slack_demo(args: Messaging) -> Result<()> {
    run_node(Service::Slack, args, true)
}

fn run_node(service: Service, args: Messaging, demo: bool) -> Result<()> {
    let (mut settings, config_path) = load(service, &args)?;
    if let Some(file) = &args.preview {
        let event: Value = serde_json::from_slice(&std::fs::read(file)?)?;
        println!("{}", preview(service, &settings, &event)?);
        return Ok(());
    }
    let interactive =
        !args.headless && std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if args.edit && !interactive {
        return Err("--edit requires an interactive terminal".into());
    }
    let sender = if demo {
        if settings.destination(service).trim().is_empty() {
            settings.set_destination(service, "#website-review".into());
        }
        Delivery::Demo
    } else {
        let resolved = crate::secrets::lookup(service.token(), settings.credential.as_deref())?;
        let refresh = resolved.is_some();
        let token = match resolved {
            Some(token) => token,
            None => crate::secrets::named(service.token(), None, !args.headless)?,
        };
        settings.set_destination(
            service,
            crate::secrets::destination(
                service.destination_env(),
                settings.destination(service),
                !args.headless,
            )?,
        );
        let mut sender = Sender::new(service, token)?;
        if refresh { sender.token.clear(); }
        Delivery::Live { sender, credential: settings.credential.clone(), refresh }
    };
    if !args.edit {
        validate_settings(&settings, service)?;
    }
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut graph_session = crate::node_session(true)?;
    graph_session.register_raw(settings.manifest(service))?;
    let mut form = if interactive {
        Some(Form::chat(
            service.name(),
            vec![
                ("Name", settings.name.clone()),
                (
                    if service == Service::Telegram {
                        "Chat ID"
                    } else {
                        "Channel ID"
                    },
                    settings.destination(service).into(),
                ),
                ("Message template · jq", settings.message_template.clone()),
            ],
        )?)
    } else {
        None
    };
    let mut active = !args.edit;
    let mut status = if active {
        "Running · waiting for events."
    } else {
        "Paused · Preview never sends. Apply starts delivery."
    }
    .to_owned();
    let mut event = Value::Null;
    let mut sample = "No incoming event yet.".to_owned();
    let mut preview_text = "Preview a queued event with F5. No message is sent.".to_owned();
    let mut poll = Instant::now() - Duration::from_secs(1);
    // Known successful parts are not resent on an in-process retry. A restart or
    // ambiguous network failure cannot promise exactly-once external delivery.
    let mut journal: HashMap<String, (Vec<Operation>, usize)> = HashMap::new();
    let mut worker: Option<(String, mpsc::Receiver<DeliveryUpdate>)> = None;
    let mut delivery_log = Vec::new();
    let mut acknowledged = std::collections::HashSet::<String>::new();
    while !STOP.load(Ordering::Relaxed) {
        graph_session.heartbeat()?;
        if let Some(form) = &mut form {
            form.set_preview(&preview_text);
            form.set_log(&delivery_log.join("\n"));
            form.set_running(active);
            match form.tick(&status, &sample)? {
                Action::Quit => {
                    STOP.store(true, Ordering::Relaxed);
                    break;
                }
                Action::Pause => {
                    active = false;
                    status = "Paused · Start resumes delivery. Any send already in progress may finish.".into();
                }
                Action::Edit => {
                    active = false;
                    status =
                        "Paused · F5 previews; Ctrl+Enter applies and resumes; Ctrl+S saves.".into();
                }
                action @ (Action::Apply | Action::Preview | Action::Save) => {
                    let candidate = values(form, &settings, service);
                    let checked = validate_settings(&candidate, service).and_then(|_| {
                        if candidate.destination(service).trim().is_empty() {
                            return Err("Destination is required".into());
                        }
                        if event != Value::Null {
                            preview_text = preview(service, &candidate, &event)?;
                        }
                        Ok(())
                    });
                    match checked {
                        Err(error) => {
                            active = false;
                            status = error.to_string();
                        }
                        Ok(()) => {
                            if matches!(action, Action::Save) {
                                status = save(&candidate, config_path.as_deref())
                                    .unwrap_or_else(|e| e.to_string());
                            } else if matches!(action, Action::Preview) {
                                status = "Preview only · nothing sent.".into();
                                active = false;
                                append_log(&mut delivery_log, interactive, "PREVIEW · not sent");
                            } else {
                                settings = candidate;
                                graph_session.register_raw(settings.manifest(service))?;
                                active = true;
                                status = "Running · applied settings.".into();
                            }
                        }
                    }
                }
                Action::None => {}
            }
        } else {
            std::thread::sleep(Duration::from_millis(50));
        }
        if let Some((id, receiver)) = &worker {
            if let Ok(update) = receiver.try_recv() {
                let id = id.clone();
                match update {
                    DeliveryUpdate::Sending(index) => {
                        status = format!("Sending to {} · part {}", service.name(), index + 1);
                        let operation = &journal[&id].0[index];
                        let destination = operation
                            .body
                            .get("chat_id")
                            .or(operation.body.get("channel"))
                            .or(operation.body.get("channel_id"))
                            .and_then(Value::as_str)
                            .unwrap_or_else(|| {
                                operation
                                    .method
                                    .split('/')
                                    .nth(1)
                                    .unwrap_or(settings.destination(service))
                            });
                        append_log(
                            &mut delivery_log,
                            interactive,
                            &format!(
                                "SENDING {} → {} · part {}\n{}",
                                service.name(),
                                destination,
                                index + 1,
                                sent_content(operation)
                            ),
                        );
                    }
                    DeliveryUpdate::Sent(completed) => {
                        if let Some(entry) = journal.get_mut(&id) {
                            entry.1 = completed;
                        }
                        append_log(
                            &mut delivery_log,
                            interactive,
                            &format!("SENT · part {completed} accepted by {}", service.name()),
                        );
                    }
                    DeliveryUpdate::Failed(completed, error) => {
                        worker = None;
                        if let Some(entry) = journal.get_mut(&id) {
                            entry.1 = completed;
                        }
                        active = false;
                        status = format!(
                            "{error}. {completed} part(s) confirmed sent; Apply retries the remaining parts."
                        );
                        append_log(
                            &mut delivery_log,
                            interactive,
                            &format!("FAILED · {status}"),
                        );
                        rpc(
                            "graph.progress",
                            json!({"event_id":id,"status":"failed","message":status}),
                        )?;
                        if form.is_none() {
                            return Err(status.into());
                        }
                    }
                    DeliveryUpdate::Finished => {
                        worker = None;
                        acknowledged.insert(id.clone());
                        graph_session.ack(&id)?;
                        journal.remove(&id);
                        status = format!("Delivered to {}.", service.name());
                        append_log(
                            &mut delivery_log,
                            interactive,
                            &format!(
                                "DELIVERED · {} → {}",
                                service.name(),
                                settings.destination(service)
                            ),
                        );
                        if args.once {
                            break;
                        }
                    }
                }
            }
        }
        if poll.elapsed() < Duration::from_millis(300) || worker.is_some() {
            continue;
        }
        poll = Instant::now();
        let batch = graph_session.take_raw()?;
        let next = batch.first().cloned();
        let Some(next) = next else {
            continue;
        };
        let id = next["event_id"]
            .as_str()
            .ok_or("Host event has no ID")?
            .to_owned();
        if acknowledged.contains(&id) {
            graph_session.ack(&id)?;
            continue;
        }
        if event != next {
            sample = serde_json::to_string_pretty(&next)?;
            event = next;
        }
        if !active {
            continue;
        }
        let prepared =
            render(&settings, &event).and_then(|message| plan(service, &settings, &message));
        let operations = match prepared {
            Ok(operations) => operations,
            Err(error) => {
                status = error.to_string();
                active = false;
                append_log(
                    &mut delivery_log,
                    interactive,
                    &format!("NOT SENT · {status}"),
                );
                rpc(
                    "graph.progress",
                    json!({"event_id":id,"status":"failed","message":status}),
                )?;
                if form.is_none() {
                    return Err(status.into());
                }
                continue;
            }
        };
        if journal
            .get(&id)
            .is_some_and(|(previous, count)| *count > 0 && previous != &operations)
        {
            active = false;
            status = "Partial delivery: restore the previous template/destination before retrying the remaining parts.".into();
            continue;
        }
        let completed = journal.get(&id).map(|v| v.1).unwrap_or(0);
        journal.insert(id.clone(), (operations.clone(), completed));
        rpc(
            "graph.progress",
            json!({"event_id":id,"status":"pending","message":format!("Sending to {}",service.name())}),
        )?;
        let sender = sender.clone();
        let pending_id = id.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut completed = completed;
            for operation in operations.iter().skip(completed) {
                if STOP.load(Ordering::Relaxed) {
                    return;
                }
                let still_pending = rpc("graph.take", json!({})).map(|batch| {
                    batch["events"].as_array().is_some_and(|events| {
                        events.iter().any(|event| event["event_id"] == pending_id)
                    })
                });
                if !matches!(still_pending, Ok(true)) {
                    let _ = tx.send(DeliveryUpdate::Failed(
                        completed,
                        "Input connection or host is no longer available".into(),
                    ));
                    return;
                }
                let _ = tx.send(DeliveryUpdate::Sending(completed));
                if let Err(error) = sender.send(operation) {
                    let _ = tx.send(DeliveryUpdate::Failed(completed, error.to_string()));
                    return;
                }
                completed += 1;
                let _ = tx.send(DeliveryUpdate::Sent(completed));
            }
            let _ = tx.send(DeliveryUpdate::Finished);
        });
        worker = Some((id, rx));
    }
    drop(form);
    if interactive {
        for entry in delivery_log {
            eprintln!("{entry}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn settings(service: Service) -> Settings {
        let mut s = Settings::defaults(service);
        s.set_destination(service, "123".into());
        s
    }
    fn message(value: Value) -> Message {
        serde_json::from_value(value).unwrap()
    }
    #[test]
    fn defaults_do_not_send_graph_metadata_and_content_replaces_fallback() {
        let s = settings(Service::Telegram);
        let m = render(&s, &json!({"text":"Done", "sessions":[{"path":"/private/session"}], "payload":{"private":"data"}, "source":"%2"})).unwrap();
        let p = plan(Service::Telegram, &s, &m).unwrap();
        assert_eq!(p[0].body, json!({"chat_id":"123","text":"Done"}));
        let p = plan(
            Service::Telegram,
            &s,
            &message(json!({"text":"fallback", "content":[{"type":"text","text":"Actual"}]})),
        )
        .unwrap();
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].body["text"], "Actual");
        assert!(
            plan(
                Service::Slack,
                &settings(Service::Slack),
                &message(json!({}))
            )
            .is_err()
        );
    }
    #[test]
    fn chunk_limits_and_native_destination_protection() {
        for (service, limit) in [
            (Service::Telegram, 4000),
            (Service::Slack, 4000),
            (Service::Discord, 2000),
        ] {
            let text = "한😀".repeat(2000);
            let p = plan(service, &settings(service), &message(json!({"text":text}))).unwrap();
            let key = if service == Service::Discord {
                "content"
            } else {
                "text"
            };
            let chunks: Vec<_> = p.iter().map(|p| p.body[key].as_str().unwrap()).collect();
            assert_eq!(chunks.concat(), text);
            assert!(chunks.iter().all(|s| s.encode_utf16().count() <= limit));
            let m =
                message(json!({"text":"x", "renderings":{service.native(): {"token":"forged"}}}));
            assert!(plan(service, &settings(service), &m).is_err());
        }
    }
    #[test]
    fn native_blocks_and_embeds_replace_common_representation() {
        for (service, field) in [(Service::Slack, "blocks"), (Service::Discord, "embeds")] {
            let native = if service == Service::Slack {
                json!([{"type":"section","text":{"type":"plain_text","text":"Built"}}])
            } else {
                json!([{"title":"Built"}])
            };
            let m = message(
                json!({"text":"fallback", "content":[{"type":"image","path":"/does/not/exist"}], "renderings":{service.native(): {field:native}}}),
            );
            let p = plan(service, &settings(service), &m).unwrap();
            assert_eq!(p.len(), 1);
            assert!(p[0].body[field].is_array());
        }
    }
    #[test]
    fn media_preflight_and_actual_upload_requests() {
        use std::io::{Read, Write};
        let path =
            std::env::temp_dir().join(format!("graffitty-media-{}.png", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"example-media-bytes").unwrap();
        for service in [Service::Telegram, Service::Discord] {
            let m = message(
                json!({"content":[{"type":"image", "path":path, "mime_type":"image/png", "caption":"Picture"}]}),
            );
            let p = plan(service, &settings(service), &m).unwrap();
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let mut sender = Sender::new(service, "test-token".into()).unwrap();
            sender.base = format!("http://{}", listener.local_addr().unwrap());
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut data = Vec::new();
                let mut buf = [0; 4096];
                loop {
                    let n = stream.read(&mut buf).unwrap();
                    data.extend_from_slice(&buf[..n]);
                    if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&data[..end]).to_lowercase();
                        let length: usize = headers
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length: "))
                            .unwrap()
                            .parse()
                            .unwrap();
                        if data.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                let body = if service == Service::Discord {
                    r#"{"id":"123"}"#
                } else {
                    r#"{"ok":true}"#
                };
                write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
                String::from_utf8(data).unwrap()
            });
            sender.send(&p[0]).unwrap();
            let request = server.join().unwrap();
            assert!(request.contains("example-media-bytes"));
            assert!(request.contains("Picture"));
            if service == Service::Discord {
                assert!(request.contains("payload_json"));
                assert!(request.contains("files[0]"));
                assert!(
                    request
                        .to_lowercase()
                        .contains("authorization: bot test-token")
                );
            } else {
                assert!(request.contains("/bottest-token/sendPhoto"));
                assert!(request.contains("name=\"photo\""));
            }
        }
        std::fs::remove_file(&path).unwrap();
        let m = message(
            json!({"text":"Must not send before checking files", "content":[{"type":"file","path":path}]}),
        );
        assert!(plan(Service::Telegram, &settings(Service::Telegram), &m).is_err());
    }
    #[test]
    fn native_save_never_contains_credentials() {
        let path =
            std::env::temp_dir().join(format!("graffitty-chat-{}.json", uuid::Uuid::new_v4()));
        let s = settings(Service::Slack);
        save(&s, Some(&path)).unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(value.get("token").is_none());
        assert_eq!(value["channel_id"], "123");
        std::fs::remove_file(path).unwrap();
    }
}

#[cfg(test)]
mod upload_tests {
    use super::*;
    use std::io::{Read, Write};
    fn receive(stream: &mut std::net::TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut data = Vec::new();
        let mut buf = [0; 4096];
        loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0);
            data.extend_from_slice(&buf[..n]);
            if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&data[..end]).to_lowercase();
                let length: usize = header
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .unwrap_or("0")
                    .parse()
                    .unwrap();
                if data.len() >= end + 4 + length {
                    return String::from_utf8(data).unwrap();
                }
            }
        }
    }
    fn respond(stream: &mut std::net::TcpStream, body: Value) {
        let body = body.to_string();
        write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
    }
    #[test]
    fn delivery_refreshes_named_credentials_and_never_sends_on_lookup_failure() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut sender = Sender::new(Service::Slack, "stale-token".into()).unwrap();
        sender.base = format!("http://{}", listener.local_addr().unwrap());
        let delivery = Delivery::Live { sender, credential: Some("work".into()), refresh: true };
        let operation = Operation { method: "chat.postMessage".into(), body: json!({"channel":"C123","text":"test"}), upload: None };
        let server = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                requests.push(receive(&mut stream));
                respond(&mut stream, json!({"ok":true}));
            }
            requests
        });
        for token in ["first-token", "second-token"] {
            delivery.send_with(&operation, |env, reference| {
                assert_eq!(env, "SLACK_BOT_TOKEN");
                assert_eq!(reference, Some("work"));
                Ok(Some(token.into()))
            }).unwrap();
        }
        let requests = server.join().unwrap();
        assert!(requests[0].contains("Bearer first-token"));
        assert!(requests[1].contains("Bearer second-token"));
        assert!(requests.iter().all(|r| !r.contains("stale-token")));
        let error = delivery.send_with(&operation, |_, _| Err("lookup failed".into())).unwrap_err();
        assert_eq!(error.to_string(), "lookup failed");
    }
    #[test]
    fn slack_external_upload_prepares_uploads_and_completes_without_forwarding_token() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server_base = base.clone();
        let server = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                requests.push(receive(&mut stream));
                respond(
                    &mut stream,
                    if index == 0 {
                        json!({"ok":true,"upload_url":format!("{server_base}/upload"),"file_id":"F123"})
                    } else {
                        json!({"ok":true})
                    },
                );
            }
            requests
        });
        let path =
            std::env::temp_dir().join(format!("graffitty-slack-{}.txt", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"slack file contents").unwrap();
        let mut settings = Settings::defaults(Service::Slack);
        settings.channel_id = Some("C123".into());
        let message: Message = serde_json::from_value(
            json!({"content":[{"type":"file","path":path,"caption":"Report"}]}),
        )
        .unwrap();
        let plan = plan(Service::Slack, &settings, &message).unwrap();
        let mut sender = Sender::new(Service::Slack, "test-private-token".into()).unwrap();
        sender.base = base;
        sender.send(&plan[0]).unwrap();
        let requests = server.join().unwrap();
        assert!(requests[0].contains("/files.getUploadURLExternal"));
        assert!(
            requests[0]
                .to_lowercase()
                .contains("authorization: bearer test-private-token")
        );
        assert!(requests[1].contains("slack file contents"));
        assert!(!requests[1].contains("test-private-token"));
        assert!(requests[2].contains("/files.completeUploadExternal"));
        assert!(
            requests[2].contains("F123")
                && requests[2].contains("C123")
                && requests[2].contains("Report")
        );
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn api_errors_do_not_echo_response_secrets() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            receive(&mut stream);
            respond(
                &mut stream,
                json!({"ok":false,"error":"test-private-token","description":"private body"}),
            );
        });
        let mut sender = Sender::new(Service::Slack, "test-private-token".into()).unwrap();
        sender.base = base;
        let error = sender
            .checked(
                sender
                    .request("chat.postMessage")
                    .json(&json!({"text":"Hi"})),
            )
            .unwrap_err()
            .to_string();
        assert!(!error.contains("test-private-token") && !error.contains("private body"));
        server.join().unwrap();
    }
}
