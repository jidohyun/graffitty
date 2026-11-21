//! Install the native plugin. Runtime code lives inside the agent process.
use crate::{agent_bridge::Result, options::Integrate};
use serde_json::json;
use std::{fs, io::Write, path::{Path, PathBuf}};

fn home() -> PathBuf {
    std::env::var_os("OPENCODE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(
                        std::env::var_os("HOME")
                            .or_else(|| std::env::var_os("USERPROFILE"))
                            .unwrap_or_default(),
                    )
                    .join(".config")
                })
                .join("opencode")
        })
}
fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::create_dir_all(path.parent().ok_or("Missing parent")?)?;
    let mut file = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
    file.write_all(bytes)?;
    file.persist(path)?;
    Ok(())
}

pub fn install(args: Integrate) -> Result<()> {
    let home = home();
    let home = if home.is_absolute() {
        home
    } else {
        std::env::current_dir()?.join(home)
    };
    let dir = home.join("plugins/graffitty");
    let config = format!(
        "// graffitty-opencode-v2\nexport const binary = {};\nexport const home = {};\n",
        json!(std::env::current_exe()?),
        json!(home)
    );
    let files = [
        (
            "package.json",
            include_str!("../integrations/opencode/package.json"),
        ),
        ("tui.js", include_str!("../integrations/opencode/tui.js")),
        (
            "server.js",
            include_str!("../integrations/opencode/server.js"),
        ),
        ("config.js", config.as_str()),
        ("loader.mjs", include_str!("../integrations/shared/loader.mjs")),
    ];
    println!("OpenCode v2 plugin: {}", dir.display());
    if args.status {
        if files
            .iter()
            .all(|(name, text)| fs::read_to_string(dir.join(name)).is_ok_and(|s| s == *text))
        {
            println!("Installed. OpenCode v2.0.32+; restart OpenCode to load the plugin.");
            return Ok(());
        }
        return Err(
            "OpenCode plugin missing or outdated; run gft integrate agent opencode --apply".into(),
        );
    }
    if dir.exists()
        && fs::read_to_string(dir.join("package.json"))
            .ok()
            .is_none_or(|s| !s.contains("\"graffitty-opencode\""))
    {
        return Err("Existing plugins/graffitty directory is not owned by Graffitty".into());
    }
    println!(
        "{} {}: {}",
        if args.apply { "Applying" } else { "Preview" },
        if args.remove {
            "removal"
        } else {
            "installation"
        },
        files.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", ")
    );
    if !args.apply {
        println!(
            "No files changed. Apply with: gft integrate agent opencode{} --apply",
            if args.remove { " --remove" } else { "" }
        );
        return Ok(());
    }
    for (name, text) in files {
        let path = dir.join(name);
        if args.remove {
            if path.exists() {
                fs::remove_file(path)?;
            }
        } else if !fs::read_to_string(&path).is_ok_and(|s| s == text) {
            write_private(&path, text.as_bytes())?;
        }
    }
    if args.remove {
        let _ = fs::remove_dir(&dir);
    } else {
        println!(
            "Run OpenCode v2 normally inside Graffitty. Restart existing OpenCode clients and their server to load both plugin entrypoints."
        );
    }
    Ok(())
}
