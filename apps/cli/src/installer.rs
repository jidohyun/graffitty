//! `gft self update` and `gft world install`: fetch an installer script, then
//! run it. The script, not this binary, holds the install steps.
//!
//! Graffitty has one installer, the current one on its website. It is the
//! same script a first install runs, it upgrades from every earlier version,
//! and a mistake in it is fixed for everyone by publishing it again; a script
//! frozen in each release could never be repaired. The website also says what
//! the latest version is and where its archives are stored.
//!
//! A world's installer still comes from the release tag of its repository.
use serde_json::Value;
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// The current Graffitty installer.
const GRAFFITTY_SCRIPT: &str =
    if cfg!(windows) { "https://graffitty.com/install.ps1" } else { "https://graffitty.com/install.sh" };
/// A world's installer, at the root of its repository. It takes the release tag as
/// its only argument.
const WORLD_SCRIPT: &str = if cfg!(windows) { "install.ps1" } else { "install.sh" };

/// Downloadable worlds `gft world install` knows: id and repository.
pub const WORLDS: &[(&str, &str)] = &[("bistro", "graffitty/bistro-world")];

pub fn self_update(version: Option<&str>) -> Result<()> {
    let exe = dunce::canonicalize(std::env::current_exe()?)?;
    let env = self_update_env(&exe, version)?;
    let script = fetch(GRAFFITTY_SCRIPT)?;
    if cfg!(windows) {
        // Windows locks a running gft.exe. The install script runs in its own
        // window and this process exits now, so nothing here holds the files
        // the script replaces.
        run_detached(&script, &env)?;
        println!("The installer continues in a new window");
        return Ok(());
    }
    run(&script, &[], &env)
}

/// The installer resolves the listing once and compares its archive checksum
/// to the installed receipt. A tag alone cannot identify a republished build.
fn self_update_env(exe: &Path, version: Option<&str>) -> Result<Vec<(&'static str, OsString)>> {
    let mut env = installation(exe).ok_or_else(|| {
        format!(
            "this gft runs from {}, not from an installed Graffitty (a development build?). \
             gft self update replaces the installed copy; install Graffitty with its installer first",
            exe.display()
        )
    })?;
    let version = match version {
        Some(version) if version != "latest" => requested_tag(version)?,
        _ => "latest".to_owned(),
    };
    env.push(("GRAFFITTY_VERSION", version.into()));
    env.push(("GRAFFITTY_INSTALL_SKIP_IF_EXISTS", "1".into()));
    Ok(env)
}

pub fn world_install(id: &str, version: Option<&str>) -> Result<()> {
    let repo = WORLDS.iter().find(|(known, _)| *known == id).map(|(_, repo)| *repo).ok_or_else(|| {
        let known: Vec<_> = WORLDS.iter().map(|(id, _)| *id).collect();
        format!("unknown world {id:?}; available: {}", known.join(", "))
    })?;
    let tag = release_tag(version, repo)?;
    println!("Installing {id} {tag} from {repo}");
    let script = fetch_script(repo, &tag, WORLD_SCRIPT)?;
    run(&script, &[tag], &[])
}

/// The variables that point the installer at the copy this gft belongs to, or
/// `None` when this gft is not part of an installation.
///
/// - macOS: `<folder>/Graffitty.app/Contents/Resources/graffitty/tools/gft`.
/// - Linux: `<installs>/<version>/tools/gft`, with an `<installs>/current` link.
/// - Windows: `%LOCALAPPDATA%\Programs\Graffitty\tools\gft.exe`, the only place
///   install.ps1 installs to.
fn installation(exe: &Path) -> Option<Vec<(&'static str, OsString)>> {
    let named = |path: &Path, name: &str| path.file_name().is_some_and(|n| n == name);
    let tools = exe.parent().filter(|tools| named(tools, "tools"))?;
    let root = tools.parent()?;
    if cfg!(target_os = "macos") {
        // root is Graffitty.app/Contents/Resources/graffitty.
        let app = root.ancestors().nth(3)?;
        let layout = named(root, "graffitty")
            && named(root.parent()?, "Resources")
            && named(app, "Graffitty.app")
            && app.join("Contents/MacOS/Graffitty").is_file();
        if !layout {
            return None;
        }
        return Some(vec![("GRAFFITTY_APP_DIR", app.parent()?.into())]);
    }
    if cfg!(windows) {
        let expected = PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join("Programs").join("Graffitty");
        let expected = dunce::canonicalize(expected).ok()?;
        return (root.as_os_str().eq_ignore_ascii_case(expected.as_os_str()) && root.join("Graffitty.exe").is_file())
            .then(Vec::new);
    }
    let installs = root.parent()?;
    let current = std::fs::symlink_metadata(installs.join("current")).ok()?;
    current.file_type().is_symlink().then(|| vec![("GRAFFITTY_INSTALL_DIR", installs.into())])
}

/// `requested` as a tag such as `v0.1.0`, with a leading `v` added if missing.
fn requested_tag(requested: &str) -> Result<String> {
    checked_tag(if requested.starts_with('v') { requested.to_string() } else { format!("v{requested}") })
}

fn checked_tag(tag: String) -> Result<String> {
    if !valid_tag(&tag) {
        return Err(format!("invalid release tag {tag:?} (expected e.g. v0.1.0)").into());
    }
    Ok(tag)
}

/// A world's tag: `requested`, or its repository's latest release when nothing
/// (or `latest`) is requested.
fn release_tag(requested: Option<&str>, repo: &str) -> Result<String> {
    match requested {
        Some(version) if version != "latest" => requested_tag(version),
        _ => checked_tag(latest_tag(repo)?),
    }
}

/// The bytes at `url`.
fn fetch(url: &str) -> Result<Vec<u8>> {
    let response = client()?.get(url).send()?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(format!("{url} was not found").into());
    }
    Ok(response.error_for_status()?.bytes()?.to_vec())
}

fn client() -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent(concat!("gft/", env!("GRAFFITTY_VERSION")))
        .timeout(Duration::from_secs(60))
        .build()?)
}

fn latest_tag(repo: &str) -> Result<String> {
    let response = client()?
        .get(format!("https://api.github.com/repos/{repo}/releases/latest"))
        .header("Accept", "application/vnd.github+json")
        .send()?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(format!("no published release found at https://github.com/{repo}/releases").into());
    }
    let release: Value = response.error_for_status()?.json()?;
    Ok(release["tag_name"].as_str().ok_or("the latest release has no tag")?.to_string())
}

/// `path` as committed at `tag`.
fn fetch_script(repo: &str, tag: &str, path: &str) -> Result<Vec<u8>> {
    let url = format!("https://raw.githubusercontent.com/{repo}/refs/tags/{tag}/{path}");
    let response = client()?.get(&url).send()?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(format!("{repo} has no {path} at {tag}").into());
    }
    Ok(response.error_for_status()?.bytes()?.to_vec())
}

fn script_file(script: &[u8]) -> Result<tempfile::NamedTempFile> {
    let suffix = if cfg!(windows) { ".ps1" } else { ".sh" };
    let mut file = tempfile::Builder::new().prefix("graffitty-install-").suffix(suffix).tempfile()?;
    std::io::Write::write_all(&mut file, script)?;
    Ok(file)
}

fn interpreter(file: &Path) -> Command {
    if cfg!(windows) {
        let mut command = Command::new("powershell");
        command.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]).arg(file);
        command
    } else {
        let mut command = Command::new("sh");
        command.arg(file);
        command
    }
}

/// Runs the script in this terminal and waits for it.
fn run(script: &[u8], args: &[String], env: &[(&str, OsString)]) -> Result<()> {
    let file = script_file(script)?;
    let status = interpreter(file.path()).args(args).envs(env.iter().map(|(k, v)| (k, v))).status()?;
    if !status.success() {
        return Err(format!("the installer failed ({status})").into());
    }
    Ok(())
}

/// Starts the script in a console window of its own and returns at once. The
/// window deletes the script and waits for Enter, so its output stays readable.
#[cfg(windows)]
fn run_detached(script: &[u8], env: &[(&str, OsString)]) -> Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
    let path = script_file(script)?.into_temp_path().keep()?;
    let quoted = format!("'{}'", path.to_string_lossy().replace('\'', "''"));
    let wrapper = format!(
        "try {{ & {quoted} }} catch {{ Write-Host ('Update failed: ' + $_) -ForegroundColor Red }} \
         finally {{ Remove-Item -LiteralPath {quoted} -ErrorAction SilentlyContinue }}; \
         Read-Host 'Press Enter to close'"
    );
    Command::new("powershell")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", &wrapper])
        .envs(env.iter().map(|(k, v)| (k, v)))
        .creation_flags(CREATE_NEW_CONSOLE)
        .spawn()?;
    Ok(())
}

#[cfg(not(windows))]
fn run_detached(_script: &[u8], _env: &[(&str, OsString)]) -> Result<()> {
    unreachable!("only Windows runs the installer detached")
}

/// `v` followed by `major.minor.patch` and an optional `-`, `.` or `+` suffix.
fn valid_tag(tag: &str) -> bool {
    let Some(rest) = tag.strip_prefix('v') else { return false };
    let core_end = rest.find(['-', '+']).unwrap_or(rest.len());
    let (core, suffix) = rest.split_at(core_end);
    let mut parts = core.splitn(4, '.');
    let numbers = (0..3).all(|_| parts.next().is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())));
    let extra = parts.next();
    let suffix_ok = |s: &str| s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-.+".contains(&b));
    numbers
        && extra.is_none_or(|e| !e.is_empty() && suffix_ok(e))
        && (suffix.is_empty() || (suffix.len() > 1 && suffix_ok(suffix)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_tags_are_versions_only() {
        for tag in ["v0.1.0", "v12.0.3", "v0.2.0-rc.1", "v1.0.0+build.5", "v1.2.3.4"] {
            assert!(valid_tag(tag), "{tag}");
        }
        for tag in ["0.1.0", "v0.1", "v0.1.0-", "va.b.c", "v0.1.0/../main", "original-assets", "v0.1.0 x"] {
            assert!(!valid_tag(tag), "{tag}");
        }
    }

    #[test]
    fn a_requested_version_gets_its_v() {
        assert_eq!(requested_tag("0.2.0").unwrap(), "v0.2.0");
        assert_eq!(requested_tag("v0.2.0").unwrap(), "v0.2.0");
        assert!(requested_tag("main").is_err());
        assert_eq!(release_tag(Some("0.2.0"), "graffitty/bistro-world").unwrap(), "v0.2.0");
    }

    #[test]
    fn unknown_worlds_are_refused_before_any_download() {
        let error = world_install("nowhere", Some("v0.0.1")).unwrap_err().to_string();
        assert!(error.contains("available: bistro"), "{error}");
    }

    #[cfg(unix)]
    #[test]
    fn only_an_installed_gft_updates_itself() {
        let root = tempfile::tempdir().unwrap();
        let root = dunce::canonicalize(root.path()).unwrap();
        // A development build is never an installation.
        std::fs::create_dir_all(root.join("target/debug")).unwrap();
        assert!(installation(&root.join("target/debug/gft")).is_none());
        let exe = if cfg!(target_os = "macos") {
            let app = root.join("Apps/Graffitty.app");
            std::fs::create_dir_all(app.join("Contents/Resources/graffitty/tools")).unwrap();
            std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
            std::fs::write(app.join("Contents/MacOS/Graffitty"), "").unwrap();
            let env = installation(&app.join("Contents/Resources/graffitty/tools/gft")).unwrap();
            assert_eq!(env, vec![("GRAFFITTY_APP_DIR", root.join("Apps").into())]);
            app.join("Contents/Resources/graffitty/tools/gft")
        } else {
            let installs = root.join("installs");
            std::fs::create_dir_all(installs.join("0.1.0/tools")).unwrap();
            assert!(installation(&installs.join("0.1.0/tools/gft")).is_none());
            std::os::unix::fs::symlink("0.1.0", installs.join("current")).unwrap();
            let env = installation(&installs.join("0.1.0/tools/gft")).unwrap();
            assert_eq!(env, vec![("GRAFFITTY_INSTALL_DIR", installs.clone().into_os_string())]);
            installs.join("0.1.0/tools/gft")
        };
        let tag = format!("v{}", env!("GRAFFITTY_VERSION"));
        for (requested, expected) in [(Some(tag.as_str()), tag.as_str()), (None, "latest")] {
            let env = self_update_env(&exe, requested).unwrap();
            assert!(env.contains(&("GRAFFITTY_VERSION", expected.into())));
            assert!(env.contains(&("GRAFFITTY_INSTALL_SKIP_IF_EXISTS", "1".into())));
        }
    }
}
