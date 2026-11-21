use crate::options::CompletionCommand;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn run(command: CompletionCommand) -> Result<(), String> {
    let CompletionCommand::Install(args) = command;
    let home = env::var_os("HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .ok_or("HOME must be set to install shell completions")?;
    let config = env_path("XDG_CONFIG_HOME", home.join(".config"));
    let data = env_path("XDG_DATA_HOME", home.join(".local/share"));
    let omz = if args.shell == "zsh" {
        oh_my_zsh_completions(&home)
    } else {
        None
    };
    let path = match args.shell.as_str() {
        "zsh" => omz
            .clone()
            .unwrap_or_else(|| home.join(".zsh/completions"))
            .join("_gft"),
        "bash" => data.join("bash-completion/completions/gft"),
        "fish" => config.join("fish/completions/gft.fish"),
        shell => return Err(format!("unsupported shell: {shell}")),
    };

    let shell = usage_rs::complete::Shell::from_name(&args.shell)
        .ok_or_else(|| format!("unsupported shell: {}", args.shell))?;
    let script = crate::options::App::completion_script(shell);
    let changed = install(&path, script.as_bytes(), args.force)?;
    println!(
        "{} {}",
        if changed {
            "Installed"
        } else {
            "Already installed:"
        },
        path.display()
    );
    match args.shell.as_str() {
        "zsh" if omz.is_some() => {
            println!(
                "Oh My Zsh discovers this completion file automatically; no .zshrc changes needed."
            );
        }
        "zsh" => {
            let rc = env_path("ZDOTDIR", home.clone()).join(".zshrc");
            println!(
                "In {}, add this before your existing compinit call:",
                rc.display()
            );
            println!("  fpath=({} $fpath)", quote(path.parent().unwrap()));
            println!(
                "If you do not already initialize completion, add:\n  autoload -Uz compinit\n  compinit"
            );
        }
        "bash" => {
            println!("To load completions now, run:\n  source {}", quote(&path));
            println!(
                "For future shells, add that line to ~/.bashrc, or load bash-completion to discover this file automatically."
            );
        }
        "fish" => println!("Fish discovers this completion file automatically."),
        _ => unreachable!(),
    }
    println!("Open a new shell, then try gft <Tab>. Keep gft on PATH.");
    Ok(())
}

fn oh_my_zsh_completions(home: &Path) -> Option<PathBuf> {
    let root = env_path("ZSH", home.join(".oh-my-zsh"));
    if root.join("oh-my-zsh.sh").is_file() {
        if let Some(custom) = env::var_os("ZSH_CUSTOM").filter(|v| !v.is_empty()) {
            return Some(PathBuf::from(custom).join("completions"));
        }
    }
    // Ask an interactive zsh for its active `fpath`. A child cannot see
    // `ZSH_CUSTOM` if .zshrc assigns it without exporting it.
    //
    // Read our output after a marker so startup banners are harmless.
    // Use the active shell configuration to tell whether Oh My Zsh is loaded.
    let output = Command::new("zsh")
        .args([
            "-i",
            "-c",
            r#"
            dir=${ZSH_CUSTOM:-$ZSH/custom}/completions
            if [[ -f "$ZSH/oh-my-zsh.sh" ]] && (( ${fpath[(Ie)$dir]} )); then
                printf '\0GRAFFITTY_OMZ\0%s\0' "$dir"
            fi
        "#,
        ])
        .env("DISABLE_AUTO_UPDATE", "true")
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    let stdout = String::from_utf8(output.stdout).ok()?;
    let (_, result) = stdout.split_once("\0GRAFFITTY_OMZ\0")?;
    let path = result.split('\0').next()?;
    (!path.is_empty()).then(|| PathBuf::from(path))
}

fn env_path(name: &str, fallback: PathBuf) -> PathBuf {
    env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or(fallback)
}

fn quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

fn install(path: &Path, contents: &[u8], force: bool) -> Result<bool, String> {
    match fs::read(path) {
        Ok(existing) if existing == contents => return Ok(false),
        Ok(_) if !force => {
            return Err(format!(
                "{} already exists with different contents; use --force to replace it",
                path.display()
            ));
        }
        Ok(_) => (),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    }
    fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    let mut options = OpenOptions::new();
    options.write(true);
    if force {
        options.create(true).truncate(true);
    } else {
        options.create_new(true);
    }
    let mut file = options
        .open(path)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    file.write_all(contents)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installation_is_idempotent_and_preserves_existing_files() {
        let dir = env::temp_dir().join(format!("graffitty-completion-{}", uuid::Uuid::new_v4()));
        let path = dir.join("completions/_gft");
        assert!(install(&path, b"generated", false).unwrap());
        assert!(!install(&path, b"generated", false).unwrap());
        fs::write(&path, b"custom").unwrap();
        assert!(
            install(&path, b"updated", false)
                .unwrap_err()
                .contains("--force")
        );
        assert_eq!(fs::read(&path).unwrap(), b"custom");
        assert!(install(&path, b"updated", true).unwrap());
        assert_eq!(fs::read(&path).unwrap(), b"updated");
        fs::remove_dir_all(dir).unwrap();
    }
}
