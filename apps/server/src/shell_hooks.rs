//! The same bundled shell hooks as the desktop frontend, in private server-owned
//! files. User startup files are read normally and are never rewritten.
use crate::shell_integration as shared;

pub struct Hooks {
    root: std::path::PathBuf,
    pub directory: std::path::PathBuf,
}
impl Hooks {
    pub fn prepare() -> std::io::Result<Self> {
        let root = std::env::temp_dir().join(format!("graffitty-shell-{}", uuid::Uuid::new_v4()));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&root)?;
        let mut hooks = Self {
            root,
            directory: Default::default(),
        };
        hooks.directory = shared::prepare(&hooks.root)?;
        Ok(hooks)
    }
    pub fn configure(
        &self,
        command: &mut portable_pty::CommandBuilder,
        shell: &str,
        environment: &std::collections::BTreeMap<String, String>,
    ) {
        let mut environment: std::collections::HashMap<_, _> = environment
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        environment.insert(
            "GRAFFITTY_RESOURCES_DIR".into(),
            self.directory.to_string_lossy().into_owned(),
        );
        command.env("GRAFFITTY_RESOURCES_DIR", &self.directory);
        shared::configure(command, shell, &environment);
    }
}
impl Drop for Hooks {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
