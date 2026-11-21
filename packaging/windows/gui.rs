//! Start the watcher before Godot loads a graphics driver. The shortcut and
//! Explorer verbs keep their GUI-subsystem entry point and raw Godot arguments.
#![windows_subsystem = "windows"]
use std::os::windows::process::CommandExt;
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let result = std::env::current_exe().and_then(|exe| {
        Command::new(exe.with_file_name("tools").join("gft.exe"))
            .args(["internal", "gpu-start"])
            .args(std::env::args_os().skip(1))
            .creation_flags(0x08000000)
            .status()
    });
    match result {
        Ok(status) => std::process::exit(status.code().unwrap_or(1)),
        Err(_) => ExitCode::FAILURE,
    }
}
