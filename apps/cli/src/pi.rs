//! Install the native plugin. Runtime code lives inside the agent process.
use crate::{agent_bridge::Result, options::Integrate};
use serde_json::json;
use std::{fs, io::Write, path::{Path, PathBuf}};

fn home() -> PathBuf {
    let user = PathBuf::from(
        std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .unwrap_or_default(),
    );
    match std::env::var("PI_CODING_AGENT_DIR")
        .ok()
        .filter(|s| !s.is_empty())
    {
        Some(s) if s == "~" => user,
        Some(s) if s.starts_with("~/") => user.join(&s[2..]),
        Some(s) => PathBuf::from(s),
        None => user.join(".pi/agent"),
    }
}
fn private(path: &Path, bytes: &[u8]) -> Result<()> {
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
    let dir = home.join("extensions/graffitty");
    let config = format!(
        "// graffitty-pi\nexport const binary = {};\nexport const home = {};\n",
        json!(std::env::current_exe()?),
        json!(home)
    );
    let files = [
        ("index.ts", include_str!("../integrations/pi/index.ts")),
        ("config.js", config.as_str()),
        ("loader.mjs", include_str!("../integrations/shared/loader.mjs")),
    ];
    println!("Pi extension: {}", dir.display());
    if args.status {
        if files
            .iter()
            .all(|(name, text)| fs::read_to_string(dir.join(name)).is_ok_and(|s| s == *text))
        {
            println!("Installed. Pi 1.3.0+; restart Pi or use /reload to load the extension.");
            return Ok(());
        }
        return Err("Pi extension missing or outdated; run gft integrate agent pi --apply".into());
    }
    if dir.exists()
        && fs::read_to_string(dir.join("index.ts"))
            .ok()
            .is_none_or(|s| !s.starts_with("// graffitty-pi\n"))
    {
        return Err("Existing extensions/graffitty directory is not owned by Graffitty".into());
    }
    println!(
        "{} {}: index.ts, config.js, loader.mjs",
        if args.apply { "Applying" } else { "Preview" },
        if args.remove {
            "removal"
        } else {
            "installation"
        }
    );
    if !args.apply {
        println!(
            "No files changed. Apply with: gft integrate agent pi{} --apply",
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
            private(&path, text.as_bytes())?;
        }
    }
    if args.remove {
        let _ = fs::remove_dir(dir);
    } else {
        println!("Run Pi normally inside Graffitty. Restart Pi or use /reload.");
    }
    Ok(())
}