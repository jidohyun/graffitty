//! Materialize bundled hooks outside the user's startup files, including PCK builds.
use portable_pty::CommandBuilder;
use std::path::{Path, PathBuf};

pub fn prepare(root: &Path) -> std::io::Result<PathBuf> {
    let dir = root.join("shell-integration-v1");
    std::fs::create_dir_all(&dir)?;
    for (name, text) in [
        (
            "integration.ps1",
            include_str!("../shell-integration/integration.ps1"),
        ),
        (
            "integration.sh",
            include_str!("../shell-integration/integration.sh"),
        ),
        (".zshenv", include_str!("../shell-integration/zshenv")),
        ("bash-env", include_str!("../shell-integration/bash-env")),
        (
            "integration.fish",
            include_str!("../shell-integration/integration.fish"),
        ),
        (
            "integration.nu",
            include_str!("../shell-integration/integration.nu"),
        ),
        (
            "integration.elv",
            include_str!("../shell-integration/integration.elv"),
        ),
        ("elvish-rc", include_str!("../shell-integration/elvish-rc")),
    ] {
        let path = dir.join(name);
        if std::fs::read_to_string(&path).ok().as_deref() != Some(text) {
            std::fs::write(path, text)?;
        }
    }
    Ok(dir)
}

pub fn configure(
    cmd: &mut CommandBuilder,
    shell: &str,
    environment: &std::collections::HashMap<String, String>,
) {
    let Some(dir) = environment.get("GRAFFITTY_RESOURCES_DIR") else {
        return;
    };
    match Path::new(shell).file_name().and_then(|s| s.to_str()) {
        Some("pwsh" | "pwsh.exe" | "powershell" | "powershell.exe") => {
            cmd.arg("-NoExit");
            cmd.arg("-Command");
            cmd.arg(format!(". '{}/integration.ps1'", dir.replace('\'', "''")));
        }
        Some("zsh") => {
            if let Some(original) = environment
                .get("ZDOTDIR")
                .cloned()
                .or_else(|| std::env::var("ZDOTDIR").ok())
            {
                cmd.env("GRAFFITTY_ORIGINAL_ZDOTDIR", original);
            } else {
                cmd.env_remove("GRAFFITTY_ORIGINAL_ZDOTDIR");
            }
            cmd.env("ZDOTDIR", dir);
        }
        Some("bash") => {
            if let Some(original) = environment
                .get("ENV")
                .cloned()
                .or_else(|| std::env::var("ENV").ok())
            {
                cmd.env("GRAFFITTY_ORIGINAL_ENV", original);
            } else {
                cmd.env_remove("GRAFFITTY_ORIGINAL_ENV");
            }
            // Long options must precede the login switch installed by command().
            cmd.get_argv_mut().insert(1, "--posix".into());
            cmd.env("ENV", Path::new(dir).join("bash-env"));
        }
        Some("fish") => {
            cmd.arg("--init-command");
            cmd.arg(format!(
                "source '{}/integration.fish'",
                dir.replace('\\', "\\\\").replace('\'', "\\'")
            ));
        }
        Some("nu") => {
            cmd.arg("--execute");
            cmd.arg(format!("source r#'{}/integration.nu'#", dir));
        }
        Some("elvish") => {
            // Elvish has no login switch; it always reads its normal rc here.
            cmd.get_argv_mut().retain(|a| a != "-l");
            cmd.arg("-rc");
            cmd.arg(Path::new(dir).join("elvish-rc"));
        }
        _ => {}
    }
}
