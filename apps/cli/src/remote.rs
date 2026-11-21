//! OpenSSH owns authentication and encryption. The server owns PTYs independently
//! of these tunnels and of the lifetime of the native frontend.
use crate::options::{RemoteCommand, RemoteConnect};
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
type Error = Box<dyn std::error::Error>;
fn ssh(host: &str) -> Command {
    let mut cmd = Command::new("ssh");
    cmd.args([
        "-o",
        "ConnectTimeout=15",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        host,
    ]);
    cmd
}
/// Copy a file into the Windows account's home directory over SFTP.
///
/// A Windows OpenSSH DefaultShell of PowerShell 7 never forwards SSH stdin to
/// a child powershell.exe, so uploads cannot be piped through a command
/// there.
fn upload_windows(host: &str, local: &Path, name: &str) -> Result<(), Error> {
    let status = Command::new("scp")
        .args(["-q", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
        .arg(local)
        .arg(format!("{host}:{name}"))
        .status()?;
    if !status.success() {
        return Err(format!("Windows upload failed: {}", local.display()).into());
    }
    Ok(())
}
fn output(host: &str, script: &str) -> Result<String, Error> {
    let result = ssh(host).arg(script).output()?;
    if !result.status.success() {
        return Err(format!(
            "SSH {host}: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(result.stdout)?.trim().into())
}
fn validate_host(host: &str) -> Result<(), Error> {
    if host.is_empty()
        || host.starts_with('-')
        || host.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err("Use an SSH hostname, user@host, or ~/.ssh/config alias".into());
    }
    Ok(())
}
fn prepare(host: &str, binary: Option<&Path>) -> Result<Value, Error> {
    validate_host(host)?;
    let platform = output(host, "uname -s; uname -m");
    if platform.as_ref().is_err() {
        return prepare_windows(host, binary);
    }
    let platform = platform?;
    let mut words = platform.lines();
    let os = words.next().unwrap_or("");
    let arch = words.next().unwrap_or("");
    if !["Linux", "Darwin"].contains(&os) {
        return prepare_windows(host, binary);
    }
    let local_os = if cfg!(target_os = "macos") {
        "Darwin"
    } else if cfg!(target_os = "linux") {
        "Linux"
    } else {
        "Windows"
    };
    let local_arch = if cfg!(target_arch = "aarch64") {
        ["arm64", "aarch64"].contains(&arch)
    } else {
        arch == std::env::consts::ARCH
    };
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let target_arch = if ["arm64", "aarch64"].contains(&arch) {
        "aarch64"
    } else {
        arch
    };
    let target_os = if os == "Darwin" { "macos" } else { "linux" };
    let bundle = root
        .join("dist/remote")
        .join(format!("{target_os}-{target_arch}"));
    let local_executable = std::env::current_exe()?;
    let default = if bundle.join("gft").is_file() {
        bundle.join("gft")
    } else {
        local_executable
    };
    let existing = output(
        host,
        "test -x \"$HOME/.local/lib/graffitty/gft\" && \"$HOME/.local/lib/graffitty/gft\" server --version >/dev/null 2>&1",
    )
    .is_ok();
    let artifact = binary.or_else(|| {
        if !existing
            && (default.starts_with(&bundle) || (os == local_os && local_arch))
            && default.is_file()
        {
            Some(default.as_path())
        } else {
            None
        }
    });
    if let Some(artifact) = artifact {
        eprintln!("Installing server on {host} ({os}/{arch})…");
        install(host, artifact, "gft")?;
        let filetree = artifact.with_file_name("filetree-runtime.tar.gz");
        if filetree.is_file() {
            install_filetree(host, &filetree)?;
        }
        if os == "Darwin" {
            let chromium = artifact.with_file_name("chromium-runtime.tar.gz");
            if chromium.is_file() {
                install_chromium(host, &chromium)?;
            }
        }
    } else if !existing {
        return Err(format!("No server installed on {host} ({os}/{arch}). Build apps/cli for that target, then pass --server-binary PATH").into());
    }
    // The binary's lock checks liveness without trusting a recycled PID. Reusing
    // a daemon never restarts shells, including after the executable is updated.
    let script = r#"set -eu
umask 077
server="$HOME/.local/lib/graffitty/gft"
state="$HOME/.local/state/graffitty"
mkdir -p "$state"
if "$server" server --connection "$state/server.json" --status 2>/dev/null; then exit 0; fi
nohup "$server" server --listen 127.0.0.1:0 --connection "$state/server.json" >"$state/server.log" 2>&1 </dev/null &
i=0
while [ "$i" -lt 100 ]; do
    if "$server" server --connection "$state/server.json" --status 2>/dev/null; then exit 0; fi
    i=$((i+1))
    sleep 0.1
done
cat "$state/server.log" >&2
exit 1
"#;
    let descriptor: Value = serde_json::from_str(&output(host, script)?)?;
    if descriptor["protocol"] != graffitty_protocol::VERSION || descriptor["token"].as_str().is_none() {
        return Err("Unsupported server descriptor".into());
    }
    Ok(descriptor)
}
// Versioned chromium bundles preserve any host already serving a live session.
fn install_chromium(host: &str, archive: &Path) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let script = format!(
        r#"set -eu
umask 077
root="$HOME/.local/lib/graffitty"
destination="$root/chromium-runtime-{nonce}"
mkdir -p "$destination"
tar -xzf - -C "$destination"
test -x "$destination/Chromium GPU Host.app/Contents/MacOS/probe"
printf '%s\n' 'chromium-runtime-{nonce}/Chromium GPU Host.app/Contents/MacOS/probe' > "$root/chromium-host-path.{nonce}"
mv "$root/chromium-host-path.{nonce}" "$root/chromium-host-path.txt"
"#
    );
    let mut child = ssh(host)
        .arg(script)
        .stdin(Stdio::from(File::open(archive)?))
        .spawn()?;
    if !child.wait()?.success() {
        return Err("Could not install the GPU chromium runtime".into());
    }
    Ok(())
}
// Versioned like the chromium runtime. A running server may still have trees on
// the previously current runtime; older ones are removed.
fn install_filetree(host: &str, archive: &Path) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let script = format!(
        r#"set -eu
umask 077
root="$HOME/.local/lib/graffitty"
destination="$root/filetree-runtime-{nonce}"
previous=$(cut -d/ -f1 "$root/filetree-runtime-path.txt" 2>/dev/null || true)
mkdir -p "$destination"
tar -xzf - -C "$destination"
test -f "$destination/filetree/manifest.json"
printf '%s\n' 'filetree-runtime-{nonce}/filetree' > "$root/filetree-runtime-path.{nonce}"
mv "$root/filetree-runtime-path.{nonce}" "$root/filetree-runtime-path.txt"
for old in "$root"/filetree-runtime-*/; do
    name=$(basename "$old")
    if [ "$name" != "filetree-runtime-{nonce}" ] && [ "$name" != "$previous" ]; then rm -rf "$old"; fi
done
"#
    );
    let mut child = ssh(host)
        .arg(script)
        .stdin(Stdio::from(File::open(archive)?))
        .spawn()?;
    if !child.wait()?.success() {
        return Err("Could not install the bundled filetree runtime".into());
    }
    Ok(())
}
fn powershell(script: &str) -> String {
    use base64::Engine;
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    format!(
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    )
}
fn prepare_windows(host: &str, binary: Option<&Path>) -> Result<Value, Error> {
    let arch = output(
        host,
        &powershell("[Console]::WriteLine($env:PROCESSOR_ARCHITECTURE)"),
    )?;
    let arch = match arch.trim() {
        "AMD64" => "x86_64",
        "ARM64" => "aarch64",
        other => return Err(format!("Unsupported Windows CPU: {other}").into()),
    };
    let bundle = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../dist/remote")
        .join(format!("windows-{arch}"));
    let default = bundle.join("gft.exe");
    let existing=output(host,&powershell("$p=Join-Path $env:LOCALAPPDATA 'graffitty/server-path.txt'; if (!(Test-Path $p)) {exit 1}; $bin=[IO.File]::ReadAllText($p).Trim(); & (Join-Path $bin 'gft.exe') server --version | Out-Null; if ($LASTEXITCODE -ne 0) {exit 1}; [Console]::WriteLine('installed')")).is_ok();
    let artifact = binary.or_else(|| {
        if !existing && default.is_file() {
            Some(default.as_path())
        } else {
            None
        }
    });
    if let Some(artifact) = artifact {
        let nonce = uuid::Uuid::new_v4().simple().to_string();
        upload_windows(host, artifact, &format!(".graffitty-upload-{nonce}.exe"))?;
        let script = format!(
            r#"$ErrorActionPreference='Stop'
$upload=Join-Path $HOME '.graffitty-upload-{nonce}.exe'
try {{
    $directory=Join-Path $env:LOCALAPPDATA 'graffitty/bin/{nonce}'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $file=Join-Path $directory 'gft.exe'
    [IO.File]::Move($upload, $file)
    & $file server --version | Out-Null
    if ($LASTEXITCODE -ne 0) {{ throw 'Executable does not match the remote Windows host' }}
}} finally {{ if (Test-Path -LiteralPath $upload) {{ Remove-Item -LiteralPath $upload -Force }} }}
"#
        );
        output(host, &powershell(&script))
            .map_err(|error| format!("Windows install failed: {}: {error}", artifact.display()))?;
        output(
            host,
            &powershell(&format!(
                r#"$root=Join-Path $env:LOCALAPPDATA 'graffitty'; [IO.File]::WriteAllText((Join-Path $root 'server-path.txt'),(Join-Path $root 'bin/{nonce}'),(New-Object Text.UTF8Encoding($false)))"#
            )),
        )?;
        let filetree = artifact.with_file_name("filetree-runtime.zip");
        if filetree.is_file() {
            install_windows_filetree(host, &filetree)?;
        }
    } else if !existing {
        return Err(format!("No Windows/{arch} server bundle. Put gft.exe in {} or pass --server-binary",bundle.display()).into());
    }
    let descriptor: Value = serde_json::from_str(&output(
        host,
        &powershell(include_str!("remote/windows-start.ps1")),
    )?)?;
    if descriptor["protocol"] != graffitty_protocol::VERSION || descriptor["token"].as_str().is_none() {
        return Err("Unsupported Windows server descriptor".into());
    }
    Ok(descriptor)
}

// The Windows form of install_filetree. The server finds the pointer in
// %LOCALAPPDATA%\graffitty, an ancestor of bin\<nonce>\gft.exe. Runtimes that a
// running Neovim still holds open stay until a later install removes them.
fn install_windows_filetree(host: &str, archive: &Path) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    upload_windows(host, archive, &format!(".graffitty-upload-{nonce}.zip"))?;
    let script = format!(
        r#"$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'graffitty'
$name='filetree-runtime-{nonce}'
$destination=Join-Path $root $name
$archive=Join-Path $HOME '.graffitty-upload-{nonce}.zip'
$pointer=Join-Path $root 'filetree-runtime-path.txt'
$previous=''
if (Test-Path -LiteralPath $pointer) {{ $previous=([IO.File]::ReadAllText($pointer).Trim() -split '/')[0] }}
[IO.Directory]::CreateDirectory($root) | Out-Null
try {{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $destination)
}} finally {{ Remove-Item -LiteralPath $archive -Force }}
if (!(Test-Path -LiteralPath (Join-Path $destination 'filetree/manifest.json'))) {{ throw 'Incomplete filetree runtime' }}
$next=$pointer + '.{nonce}'
try {{
    [IO.File]::WriteAllText($next, $name + '/filetree', (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $pointer) {{ [IO.File]::Replace($next, $pointer, [NullString]::Value) }} else {{ [IO.File]::Move($next, $pointer) }}
}} finally {{ if (Test-Path -LiteralPath $next) {{ Remove-Item -LiteralPath $next -Force }} }}
Get-ChildItem -LiteralPath $root -Directory -Filter 'filetree-runtime-*' | Where-Object {{ $_.Name -ne $name -and $_.Name -ne $previous }} | ForEach-Object {{ Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }}
"#
    );
    output(host, &powershell(&script))
        .map_err(|error| format!("Could not install the bundled filetree runtime on Windows: {error}"))?;
    Ok(())
}

fn install(host: &str, artifact: &Path, name: &str) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let script = format!(
        r#"set -eu
umask 077
mkdir -p "$HOME/.local/lib/graffitty"
tmp="$HOME/.local/lib/graffitty/.{name}-{nonce}"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat > "$tmp"
chmod 700 "$tmp"
"$tmp" server --version >/dev/null
mv -f "$tmp" "$HOME/.local/lib/graffitty/{name}"
"#
    );
    let mut child = ssh(host)
        .arg(script)
        .stdin(Stdio::from(File::open(artifact)?))
        .spawn()?;
    if !child.wait()?.success() {
        return Err(format!(
            "Upload failed: {} must match the remote OS/CPU",
            artifact.display()
        )
        .into());
    }
    Ok(())
}
struct Tunnel {
    host: String,
    port: u16,
    remote: u16,
    child: Child,
    retry: Instant,
}
impl Tunnel {
    fn command(host: &str, port: u16, remote: u16) -> Command {
        let mut command = Command::new("ssh");
        command.args([
            "-N",
            "-T",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ConnectTimeout=15",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            "-L",
            &format!("127.0.0.1:{port}:127.0.0.1:{remote}"),
            host,
        ]);
        command
    }
    fn new(host: &str, remote: u16) -> Result<Self, Error> {
        let reservation = TcpListener::bind("127.0.0.1:0")?;
        let port = reservation.local_addr()?.port();
        drop(reservation);
        let child = Self::command(host, port, remote).spawn()?;
        Ok(Self {
            host: host.into(),
            port,
            remote,
            child,
            retry: Instant::now(),
        })
    }
    fn poll(&mut self) -> Result<(), Error> {
        if self.child.try_wait()?.is_some() && self.retry.elapsed() > Duration::from_secs(2) {
            eprintln!("Reconnecting SSH tunnel to {}…", self.host);
            self.child = Self::command(&self.host, self.port, self.remote).spawn()?;
            self.retry = Instant::now();
        }
        Ok(())
    }
}
impl Drop for Tunnel {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
struct ConnectionFile(PathBuf);
impl Drop for ConnectionFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn launch_client(path: &Path) -> Result<Child, Error> {
    let exe = std::env::current_exe()?;
    let parent = exe.parent().ok_or("No executable parent")?;
    if parent.join("../../../MacOS/GraffittyRuntime").is_file() && parent.join("gft-gui").is_file() {
        return Ok(Command::new(parent.join("gft-gui"))
            .arg("--")
            .arg(format!("--remote-connections={}", path.display()))
            .spawn()?);
    }
    #[cfg(any(windows, target_os = "linux"))]
    {
        let launcher = parent.join("..").join(if cfg!(windows) { "Graffitty.exe" } else { "gft-gui" });
        if launcher.is_file() {
            return Ok(Command::new(launcher)
                .arg("--")
                .arg(format!("--remote-connections={}", path.display()))
                .spawn()?);
        }
    }
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let bundled = parent.join("GraffittyRuntime").is_file();
    let root = if bundled {
        parent.join("../Resources/graffitty")
    } else if checkout.join("frontends/godot/project/project.godot").is_file() {
        checkout.join("frontends/godot/project")
    } else {
        parent.join("..")
    };
    let runtime = std::env::var_os("GRAFFITTY_GODOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if bundled {
                parent.join("GraffittyRuntime")
            } else {
                PathBuf::from("godot")
            }
        });
    let mut command = Command::new(runtime);
    command.arg("--path").arg(&root);
    if !root.join("project.godot").is_file() {
        command.arg("--main-pack").arg(root.join("terminal.pck"));
    }
    command
        .arg("res://scenes/terminal.tscn")
        .arg("--")
        .arg(format!("--remote-connections={}", path.display()));
    Ok(command.spawn()?)
}
pub fn run(command: RemoteCommand) -> Result<(), Error> {
    let RemoteCommand::Connect(RemoteConnect {
        hosts,
        alias,
        workspace,
        server_binary,
        no_gui,
    }) = command;
    let running = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let stop = running.clone();
    ctrlc::set_handler(move || stop.store(false, std::sync::atomic::Ordering::Relaxed))?;
    if hosts.is_empty() {
        return Err("Specify one or more SSH hosts".into());
    }
    if let Some(alias) = &alias {
        if hosts.len() != 1 || !graffitty_protocol::controller::valid_alias(alias) {
            return Err("--alias requires one host and 1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number".into());
        }
    }
    if workspace.len() > 64
        || !workspace
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    {
        return Err(
            "Workspace must be empty or use 1–64 letters, numbers, dots, underscores or hyphens".into(),
        );
    }
    let mut tunnels = Vec::new();
    let mut connections = vec![];
    let mut controllers = Vec::new();
    for host in hosts {
        let descriptor = prepare(&host, server_binary.as_deref().map(Path::new))?;
        let remote: u16 = descriptor["url"]
            .as_str()
            .ok_or("Missing URL")?
            .rsplit(':')
            .next()
            .ok_or("Missing port")?
            .parse()?;
        let tunnel = Tunnel::new(&host, remote)?;
        let url = format!("ws://127.0.0.1:{}", tunnel.port);
        let identity = format!("ssh:{host}");
        if no_gui && let Some(alias) = &alias {
            let deadline = Instant::now() + Duration::from_secs(15);
            while std::net::TcpStream::connect(("127.0.0.1", tunnel.port)).is_err() {
                if Instant::now() >= deadline { return Err("SSH tunnel did not become ready".into()); }
                thread::sleep(Duration::from_millis(25));
            }
            let authenticated = graffitty_transport::authenticate(&url, descriptor["token"].as_str().ok_or("Missing server password")?, None)
                .map_err(|e| e.to_string())?;
            let graffitty_transport::Authentication::Connected(transport) = authenticated else {
                return Err("This server requires Telegram verification; connect through the GUI".into());
            };
            controllers.push(graffitty_transport::controller::Attached::new(transport,
                &graffitty_transport::controller::state_directory().map_err(|e| e.to_string())?, alias, &identity)
                .map_err(|e| e.to_string())?);
        }
        connections.push(json!({"name":host,"alias":alias.as_deref().unwrap_or(""),"credential_id":identity,"transient":true,"url":url,"token":descriptor["token"],"initial_session":workspace}));
        tunnels.push(tunnel);
    }
    let path = std::env::temp_dir().join(format!(
        "graffitty-connections-{}.json",
        uuid::Uuid::new_v4()
    ));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path)?;
    file.write_all(json!({"connections":connections}).to_string().as_bytes())?;
    let connection_file = ConnectionFile(path);
    let mut gui = if no_gui {
        println!("{}", connection_file.0.display());
        None
    } else {
        Some(launch_client(&connection_file.0)?)
    };
    eprintln!("SSH tunnels are active. Closing the client detaches; server shells keep running.");
    while running.load(std::sync::atomic::Ordering::Relaxed) {
        if let Some(gui) = gui.as_mut() {
            if gui.try_wait()?.is_some() {
                return Ok(());
            }
        }
        for tunnel in &mut tunnels {
            tunnel.poll()?;
        }
        for controller in &mut controllers { controller.poll().map_err(|e| e.to_string())?; }
        thread::sleep(Duration::from_millis(if controllers.is_empty() { 100 } else { 5 }));
    }
    if let Some(gui) = gui.as_mut() {
        let _ = gui.kill();
        let _ = gui.wait();
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn destinations_cannot_inject_ssh_options() {
        for s in ["-oProxyCommand=evil", "bad\nname", ""] {
            assert!(validate_host(s).is_err());
        }
        assert!(validate_host("user@build-server").is_ok());
    }
}
