//! Native test frontend for the CLI's restore process/receipt handshake.
use std::{env, fs, process::{Command, Stdio}};
fn main() {
    let mut args = env::args_os().skip(1);
    assert_eq!(args.next().as_deref(), Some(std::ffi::OsStr::new("--")));
    let log = fs::File::create(env::var_os("CHECKPOINT_TEST_LOG").unwrap()).unwrap();
    let mut child = Command::new(env::var_os("GRAFFITTY_TEST_GODOT").unwrap())
        .args(["--headless", "--path"])
        .arg(env::var_os("GRAFFITTY_TEST_PROJECT").unwrap())
        .args(["--script", "res://tests/checkpoint_restore_smoke.gd", "--"])
        .args(args).stdin(Stdio::null())
        .stderr(log.try_clone().unwrap()).stdout(log).spawn().unwrap();
    fs::write(env::var_os("CHECKPOINT_TEST_PID").unwrap(), child.id().to_string()).unwrap();
    std::process::exit(child.wait().unwrap().code().unwrap_or(1));
}
