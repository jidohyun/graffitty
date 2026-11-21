//! Typed server defaults. Explicit per-session options override spawn defaults.
use figment::{
    Figment,
    providers::{Env, Format, Serialized, Toml},
};
use graffitty_protocol::limits::TerminalLimits;
use graffitty_protocol::spawn::SpawnOptions;
use graffitty_workspace_core::graph::NodeSettings;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::Path};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Settings {
    pub navigator: crate::navigator::Config,
    pub terminal: Terminal,
    pub filetree: Filetree,
    pub chromium: Chromium,
    pub nodes: NodeSettings,
    pub workers: Workers,
    pub remote: Remote,
    pub checkpoints: Checkpoints,
    pub dictation: crate::dictation::Config,
    pub resource_monitor: ResourceMonitor,
}
/// Process accounting for terminals and Chromium panes.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ResourceMonitor {
    pub cpu_percent_scale: CpuPercentScale,
}
/// What 100% CPU means: every logical CPU the server may use, as in Task
/// Manager, or one fully busy logical CPU, as in top and Activity Monitor.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CpuPercentScale {
    #[default]
    AllCores,
    OneCore,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Checkpoints {
    pub enabled: bool,
    pub interval_seconds: u64,
    pub history: usize,
}
impl Default for Checkpoints {
    fn default() -> Self {
        Self { enabled: true, interval_seconds: 1800, history: 20 }
    }
}
/// Empty `command` runs the bundled, sandboxed Neovim filetree. Otherwise the
/// server runs this Neovim command (executable, then arguments) with
/// `environment`, adding only its integration `--cmd` and `--listen` options.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Filetree {
    pub command: Vec<String>,
    pub environment: BTreeMap<String, String>,
    /// Effects held off in the connected pane and the tree while a filetree
    /// is open (effect names or groups; see docs/developers/automation-and-extensions/effect-holds.md).
    pub hold_effects: Vec<String>,
}
impl Filetree {
    pub fn validate(&self) -> Result<(), String> {
        if let Some(name) = self.hold_effects.iter().find(|n| !graffitty_protocol::osc::valid_effect(n)) {
            return Err(format!("filetree.hold_effects: unknown effect {name:?}"));
        }
        if self.command.is_empty() {
            if !self.environment.is_empty() {
                return Err("filetree.environment applies only to a custom filetree.command".into());
            }
            return Ok(());
        }
        if self.command[0].trim().is_empty() || self.command.iter().any(|v| v.chars().any(char::is_control)) {
            return Err("filetree.command must list a Neovim executable, then its arguments".into());
        }
        SpawnOptions {
            shell: Some(self.command[0].clone()),
            args: self.command[1..].to_vec(),
            env: self.environment.clone(),
            ..Default::default()
        }
        .validate()
        .map_err(|error| format!("filetree: {error}"))
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Chromium {
    pub backend: ChromiumBackend,
    /// Empty creates a temporary profile. Paths are interpreted on the server.
    pub profile: String,
    /// Profile copied into each chromium's temporary session when `profile` is empty.
    pub profile_template: String,
    /// Absolute server path, or a path beneath %(temp) / %(state).
    pub sessions_directory: String,
    pub delete_session_on_close: bool,
}
impl Default for Chromium {
    fn default() -> Self {
        Self {
            backend: ChromiumBackend::Chrome,
            profile: String::new(),
            profile_template: String::new(),
            sessions_directory: "%(temp)/graffitty/chromium/sessions".into(),
            delete_session_on_close: true,
        }
    }
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChromiumBackend {
    Alloy,
    #[default]
    Chrome,
}
impl ChromiumBackend {
    pub fn name(self) -> &'static str {
        match self { Self::Alloy => "alloy", Self::Chrome => "chrome" }
    }
}
impl Chromium {
    pub fn sessions_path(&self) -> Result<std::path::PathBuf, String> {
        use std::path::{Component, PathBuf};
        let value = &self.sessions_directory;
        if value.is_empty() || value.chars().any(char::is_control) {
            return Err("chromium.sessions_directory must name a server directory".into());
        }
        let path = if let Some(relative) = value.strip_prefix("%(temp)/") {
            (std::env::temp_dir(), relative)
        } else if let Some(relative) = value.strip_prefix("%(state)/") {
            (graffitty_protocol::server_state_directory().ok_or("Cannot resolve the server state directory")?, relative)
        } else {
            (PathBuf::new(), value.as_str())
        };
        if !path.0.as_os_str().is_empty() && (path.1.is_empty()
            || Path::new(path.1).components().any(|c| !matches!(c, Component::Normal(_) | Component::CurDir))) {
            return Err("chromium.sessions_directory placeholder suffix must stay beneath its base directory".into());
        }
        let path = path.0.join(path.1);
        if !path.is_absolute() || (path.exists() && !path.is_dir()) {
            return Err("chromium.sessions_directory must be an absolute directory or use %(temp)/ or %(state)/".into());
        }
        Ok(path)
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Terminal {
    pub font: crate::fonts::Config,
    pub content_insets: [f64; 4],
    pub workspace_size: [u16; 2],
    /// Default shell command: the executable (searched on `PATH`), then its literal
    /// arguments. An explicit `--shell` or a spawn request that names its own shell
    /// replaces the whole command.
    pub shell: Option<Vec<String>>,
    pub login_shell: bool,
    pub shell_integration: bool,
    pub environment: BTreeMap<String, String>,
    pub limits: TerminalLimits,
}
impl Default for Terminal {
    fn default() -> Self {
        Self {
            font: Default::default(),
            content_insets: [12., 38., 12., 12.],
            workspace_size: [1280, 800],
            shell: None,
            login_shell: cfg!(unix),
            shell_integration: false,
            environment: BTreeMap::new(),
            limits: TerminalLimits::default(),
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Workers {
    pub concurrency: usize,
    pub timeout_seconds: u64,
    pub output_bytes: usize,
}
impl Default for Workers {
    fn default() -> Self {
        Self {
            concurrency: 4,
            timeout_seconds: 30,
            output_bytes: 4 * 1024 * 1024,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Remote {
    pub enabled: bool,
    pub bind_address: String,
    pub port: u16,
}
impl Default for Remote {
    fn default() -> Self {
        Self {
            enabled: false,
            bind_address: "127.0.0.1".into(),
            port: graffitty_protocol::DEFAULT_REMOTE_PORT,
        }
    }
}
impl Settings {
    pub fn load(path: &Path, explicit: bool) -> Result<Self, Box<dyn std::error::Error>> {
        // Missing default files are fine; permission errors and explicit missing files are not.
        let mut config = Figment::from(Serialized::defaults(Self::default()));
        match std::fs::read_to_string(path) {
            Ok(source) => {
                config = config.merge(Toml::string(&source));
            }
            Err(error) if !explicit && error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("{}: {error}", path.display()).into()),
        }
        let settings: Self = config
            .merge(
                Env::prefixed("GRAFFITTY_SERVER__")
                    .split("__")
                    .map(|key| {
                        let text = key.as_str();
                        let lower = text.to_ascii_lowercase();
                        // Environment variable names keep their case.
                        match ["terminal.environment.", "filetree.environment."]
                            .into_iter()
                            .find(|prefix| lower.starts_with(prefix))
                        {
                            Some(prefix) => format!("{prefix}{}", &text[prefix.len()..]).into(),
                            None => lower.into(),
                        }
                    })
                    .lowercase(false),
            )
            .extract()
            .map_err(|error| format!("{}: {error}", path.display()))?;
        settings.validate()?;
        Ok(settings)
    }
    pub fn validate(&self) -> Result<(), String> {
        self.chromium.sessions_path()?;
        if !(1..=86400).contains(&self.checkpoints.interval_seconds) || !(1..=10000).contains(&self.checkpoints.history) {
            return Err("checkpoints.interval_seconds must be 1–86400; checkpoints.history must be 1–10000".into());
        }
        self.filetree.validate()?;
        if !self.chromium.profile.is_empty() {
            let path = Path::new(&self.chromium.profile);
            if !path.is_absolute() || (path.exists() && !path.is_dir()) || self.chromium.profile.chars().any(char::is_control) {
                return Err("chromium.profile must be an absolute directory path on the server, or empty for a temporary profile".into());
            }
            if !self.chromium.profile_template.is_empty() {
                return Err("Set either chromium.profile or chromium.profile_template, not both".into());
            }
        }
        if !self.chromium.profile_template.is_empty() {
            let path = Path::new(&self.chromium.profile_template);
            if !path.is_absolute() || (path.exists() && !path.is_dir()) || self.chromium.profile_template.chars().any(char::is_control) {
                return Err("chromium.profile_template must be an absolute directory path on the server".into());
            }
        }
        if self.terminal.shell.as_ref().is_some_and(Vec::is_empty) {
            return Err("terminal.shell must list an executable, then its arguments".into());
        }
        self.spawn_options(None).validate()?;
        self.terminal.font.validate()?;
        if !(320..=32768).contains(&self.terminal.workspace_size[0]) || !(240..=32768).contains(&self.terminal.workspace_size[1]) { return Err("terminal.workspace_size must be 320–32768 by 240–32768 logical pixels".into()); }
        if self.terminal.content_insets.iter().any(|v| !v.is_finite() || !(4.0..=256.0).contains(v)) { return Err("terminal.content_insets must contain four finite pixel values between 4 and 256".into()); }
        self.nodes.validate()?;
        self.dictation.validate()?;
        self.navigator.validate()?;
        if self.workers.concurrency == 0
            || self.workers.timeout_seconds == 0
            || self.workers.output_bytes == 0
            || self.workers.output_bytes > isize::MAX as usize
        {
            return Err("workers values must be positive; output_bytes must fit in isize".into());
        }
        if self.remote.port == 0
            || self
                .remote
                .bind_address
                .parse::<std::net::IpAddr>()
                .is_err()
        {
            return Err("remote requires a valid IP bind_address and a nonzero port".into());
        }
        Ok(())
    }
    pub fn spawn_options(&self, requested: Option<&SpawnOptions>) -> SpawnOptions {
        let (shell, args) = match self.terminal.shell.as_deref() {
            Some([program, args @ ..]) => (Some(program.clone()), args.to_vec()),
            _ => (None, Vec::new()),
        };
        let mut result = SpawnOptions {
            shell,
            args,
            login: Some(self.terminal.login_shell),
            shell_integration: Some(self.terminal.shell_integration),
            env: self.terminal.environment.clone(),
            scrollback_bytes: Some(self.terminal.limits.scrollback_bytes),
            kitty_image_storage_mb: Some(self.terminal.limits.kitty_image_storage_mb),
            kitty_image_transmission_mib: Some(self.terminal.limits.kitty_image_transmission_mib),
            ..Default::default()
        };
        if let Some(request) = requested {
            macro_rules! overlay { ($($field:ident),*) => { $(if request.$field.is_some() { result.$field = request.$field.clone(); })* }; }
            overlay!(
                shell,
                login,
                cwd,
                shell_integration,
                scrollback_bytes,
                kitty_image_storage_mb,
                kitty_image_transmission_mib
            );
            result.env.extend(request.env.clone());
            if request.shell.is_some() || !request.args.is_empty() {
                result.args.clone_from(&request.args);
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parse(source: &str) -> Result<Settings, figment::Error> {
        Figment::from(Serialized::defaults(Settings::default()))
            .merge(Toml::string(source))
            .extract()
    }
    #[test]
    fn navigation_policy_is_loaded_from_server_settings() {
        assert!(!parse("").unwrap().navigator.enabled);
        let settings = parse("[navigator]\nenabled=true\nfiletree=false\nalgorithm='nearest'\n[navigator.bindings]\n'ctrl+h'='right'").unwrap();
        settings.validate().unwrap();
        assert!(settings.navigator.enabled);
        assert!(!settings.navigator.filetree);
        assert_eq!(settings.navigator.algorithm, "nearest");
        assert_eq!(settings.navigator.bindings["ctrl+h"], "right");
        assert!(parse("[navigator]\nalgorithm='unknown'").unwrap().validate().is_err());
        assert!(parse("[navigator]\nunknown=true").is_err());
    }
    #[test]
    fn cpu_percent_scale_defaults_to_all_cores_and_accepts_one_core() {
        let scale = |source: &str| parse(source).unwrap().resource_monitor.cpu_percent_scale;
        assert_eq!(scale(""), CpuPercentScale::AllCores);
        assert_eq!(scale("[resource_monitor]\ncpu_percent_scale='all_cores'"), CpuPercentScale::AllCores);
        assert_eq!(scale("[resource_monitor]\ncpu_percent_scale='one_core'"), CpuPercentScale::OneCore);
        for value in ["machine", "core", "cores", "all-cores", "", "AllCores"] {
            assert!(parse(&format!("[resource_monitor]\ncpu_percent_scale='{value}'")).is_err());
        }
        for key in ["cpu_percent", "interval"] {
            assert!(parse(&format!("[resource_monitor]\n{key}='all_cores'")).is_err());
        }
    }
    #[test]
    fn chromium_backend_defaults_to_chrome_and_accepts_only_current_names() {
        assert_eq!(parse("").unwrap().chromium.backend, ChromiumBackend::Chrome);
        assert_eq!(parse("[chromium]\nbackend='chrome'").unwrap().chromium.backend, ChromiumBackend::Chrome);
        assert_eq!(parse("[chromium]\nbackend='alloy'").unwrap().chromium.backend, ChromiumBackend::Alloy);
        for value in ["chromium", "osr", "experimental", "", "Chrome"] {
            assert!(parse(&format!("[chromium]\nbackend='{value}'")).is_err());
        }
    }
    #[test]
    fn chromium_session_storage_paths_and_retention_are_server_settings() {
        let defaults = parse("").unwrap();
        assert!(defaults.chromium.delete_session_on_close);
        assert_eq!(defaults.chromium.sessions_path().unwrap(), std::env::temp_dir().join("graffitty/chromium/sessions"));
        let configured = parse("[chromium]\nsessions_directory='%(state)/chromium/sessions'\ndelete_session_on_close=false").unwrap();
        configured.validate().unwrap();
        assert!(!configured.chromium.delete_session_on_close);
        assert!(configured.chromium.sessions_path().unwrap().ends_with("graffitty/chromium/sessions"));
        let custom = Chromium { sessions_directory: std::env::temp_dir().join("custom-chromium-sessions").to_string_lossy().into_owned(), ..Chromium::default() };
        assert_eq!(custom.sessions_path().unwrap(), Path::new(&custom.sessions_directory));
        for value in ["", "relative", "%(other)/sessions", "%(state)/../sessions", "%(temp)//sessions", "stdpath(\"state\")/chromium/sessions", "%(state)/", "%(temp)"] {
            assert!(Chromium { sessions_directory: value.into(), ..Chromium::default() }.sessions_path().is_err(), "{value}");
        }
        assert!(parse("[chromium]\ndelete_session_on_close='yes'").is_err());
        assert!(parse("[browser]\nprofile='old-profile'").is_err());
        let template = std::env::temp_dir().join("graffitty-template").to_string_lossy().into_owned();
        parse(&format!("[chromium]\nprofile_template='{template}'")).unwrap().validate().unwrap();
        assert!(parse("[chromium]\nprofile_template='relative'").unwrap().validate().is_err());
        assert!(parse(&format!("[chromium]\nprofile='{template}'\nprofile_template='{template}'")).unwrap().validate().is_err());
    }
    #[test]
    fn automatic_checkpoints_are_enabled_and_configurable() {
        let defaults = parse("").unwrap();
        assert!(defaults.checkpoints.enabled);
        assert_eq!(defaults.checkpoints.interval_seconds, 1800);
        assert_eq!(defaults.checkpoints.history, 20);
        let disabled = parse("[checkpoints]\nenabled = false\ninterval_seconds = 300\nhistory = 10").unwrap();
        disabled.validate().unwrap();
        assert!(!disabled.checkpoints.enabled);
        for source in ["[checkpoints]\ninterval_seconds = 0", "[checkpoints]\nhistory = 0"] {
            assert!(parse(source).unwrap().validate().is_err());
        }
    }
    #[test]
    fn filetree_defaults_to_bundled_and_accepts_a_custom_neovim_command() {
        let defaults = parse("").unwrap();
        assert!(defaults.filetree.command.is_empty() && defaults.filetree.environment.is_empty());
        let custom = parse("[filetree]\ncommand=['nvim','-u','/home/me/.config/nvim-tree/init.lua']\n[filetree.environment]\nNVIM_APPNAME='nvim-tree'").unwrap();
        custom.validate().unwrap();
        assert_eq!(custom.filetree.command, ["nvim", "-u", "/home/me/.config/nvim-tree/init.lua"]);
        assert_eq!(custom.filetree.environment["NVIM_APPNAME"], "nvim-tree");
        let held = parse("[filetree]\nhold_effects=['pane_zoom','camera']").unwrap();
        held.validate().unwrap();
        assert_eq!(held.filetree.hold_effects, ["pane_zoom", "camera"]);
        assert!(defaults.filetree.hold_effects.is_empty());
        for source in [
            "[filetree]\nhold_effects=['glitter']",
            "[filetree]\ncommand=['']",
            "[filetree]\ncommand=['nvim',\"a\\u0007b\"]",
            "[filetree.environment]\nNVIM_APPNAME='orphan'",
            "[filetree]\ncommand=['nvim']\n[filetree.environment]\nGRAFFITTY_TOKEN='x'",
            "[filetree]\ncommand=['nvim']\n[filetree.environment]\n'BAD-NAME'='x'",
        ] {
            assert!(parse(source).unwrap().validate().is_err(), "{source}");
        }
        assert!(parse("[filetree]\ncommand='nvim'").is_err());
        for removed in ["neovim_executable='nvim'", "appname='nvim-graffitty-filetree'"] {
            assert!(parse(&format!("[filetree]\n{removed}")).is_err(), "{removed}");
        }
    }
    #[test]
    fn nested_settings_preserve_defaults_and_session_overrides() {
        let settings = parse("[terminal.limits]\nkitty_image_storage_mb=123\n[nodes]\npending_per_node=2\n[workers]\nconcurrency=1").unwrap();
        settings.validate().unwrap();
        let result = settings.spawn_options(Some(&SpawnOptions {
            login: Some(false),
            ..Default::default()
        }));
        assert_eq!(result.kitty_image_storage_mb, Some(123));
        assert_eq!(result.kitty_image_transmission_mib, Some(32));
        assert_eq!(result.login, Some(false));
        assert_eq!(settings.nodes.pending_per_node, 2);
        assert_eq!(settings.nodes.run_messages, 10000);
        assert_eq!(settings.workers.timeout_seconds, 30);
    }
    #[test]
    fn shell_command_is_an_executable_then_its_arguments() {
        let settings = parse("[terminal]\nshell=['pwsh.exe','-NoLogo']").unwrap();
        settings.validate().unwrap();
        let default = settings.spawn_options(Some(&SpawnOptions { login: Some(false), ..Default::default() }));
        assert_eq!((default.shell.as_deref(), default.args), (Some("pwsh.exe"), vec!["-NoLogo".to_owned()]));
        let bare = parse("[terminal]\nshell=['pwsh.exe']").unwrap().spawn_options(None);
        assert_eq!((bare.shell.as_deref(), bare.args), (Some("pwsh.exe"), Vec::<String>::new()));
        let own_shell = settings.spawn_options(Some(&SpawnOptions { shell: Some("bash".into()), ..Default::default() }));
        assert_eq!((own_shell.shell.as_deref(), own_shell.args), (Some("bash"), Vec::<String>::new()));
        let own_args = settings.spawn_options(Some(&SpawnOptions { args: vec!["-NoProfile".into()], ..Default::default() }));
        assert_eq!(own_args.args, vec!["-NoProfile".to_owned()]);
        assert!(parse("[terminal]\nshell='pwsh.exe'").is_err());
        for source in ["[terminal]\nshell=[]", "[terminal]\nshell=['']", "[terminal]\nshell=[\"pwsh.exe\", \"-No\\u0000Logo\"]"] {
            assert!(parse(source).unwrap().validate().is_err(), "{source}");
        }
    }
    #[test]
    fn invalid_fields_types_and_ranges_are_rejected() {
        assert!(parse("[localization]\nlanguage=12").is_err());
        assert!(parse("[limits]\nkitty_image_storage_mb=123").is_err());
        assert!(parse("[nodes]\npending_per_node='two'").is_err());
        for source in [
            "[nodes]\nrun_messages=0",
            "[terminal.limits]\nkitty_image_transmission_mib=0",
            "[workers]\ntimeout_seconds=0",
            "[terminal.font]\nsize=0",
            "[terminal.font]\nline_height=0.1",
            "[terminal]\nworkspace_size=[100,100]",
            "[dictation]\nprovider='openrouter'",
            "[dictation.providers.openrouter]\nmodel='openai/gpt-transcribe'\ncredential='unsupported'\nbase_url='https://example.com/v1'",
        ] {
            assert!(parse(source).unwrap().validate().is_err());
        }
    }
    #[test]
    fn file_and_environment_precedence() {
        if let Ok(path) = std::env::var("GRAFFITTY_SETTINGS_TEST_FILE") {
            let settings = Settings::load(Path::new(&path), true).unwrap();
            assert_eq!(settings.terminal.limits.kitty_image_storage_mb, 123);
            assert_eq!(settings.nodes.pending_per_node, 3);
            assert_eq!(
                settings
                    .terminal
                    .environment
                    .get("EDITOR")
                    .map(String::as_str),
                Some("nvim"),
                "{:?}",
                settings.terminal.environment
            );
            assert!(!settings.terminal.environment.contains_key("editor"));
            assert_eq!(settings.filetree.command, ["nvim", "-u", "/tmp/tree init.lua"]);
            assert_eq!(settings.filetree.environment.get("NVIM_APPNAME").map(String::as_str), Some("nvim-tree"));
            return;
        }
        let directory =
            std::env::temp_dir().join(format!("graffitty-settings-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("server.toml");
        assert!(Settings::load(&path, true).is_err());
        assert!(Settings::load(&path, false).is_ok());
        std::fs::write(
            &path,
            "[terminal.limits]\nkitty_image_storage_mb=123\n[nodes]\npending_per_node=2",
        )
        .unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "settings::tests::file_and_environment_precedence",
            ])
            .env("GRAFFITTY_SETTINGS_TEST_FILE", &path)
            .env("GRAFFITTY_SERVER__NODES__PENDING_PER_NODE", "3")
            .env("GRAFFITTY_SERVER__TERMINAL__ENVIRONMENT__EDITOR", "nvim")
            .env("GRAFFITTY_SERVER__FILETREE__COMMAND", r#"["nvim", "-u", "/tmp/tree init.lua"]"#)
            .env("GRAFFITTY_SERVER__FILETREE__ENVIRONMENT__NVIM_APPNAME", "nvim-tree")
            .status()
            .unwrap();
        std::fs::remove_dir_all(directory).unwrap();
        assert!(status.success());
    }
    #[test]
    fn example_matches_existing_server_defaults() {
        let settings = parse(include_str!("../../../examples/server.toml")).unwrap();
        settings.validate().unwrap();
        assert_eq!(
            serde_json::to_value(&settings).unwrap(),
            serde_json::to_value(Settings::default()).unwrap()
        );
    }
}
