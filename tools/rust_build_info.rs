//! Shared application version for the CLI, server, and terminal engine.
use std::{env, path::Path, process::Command};

pub fn emit() {
    let manifest = env::var("CARGO_MANIFEST_DIR").expect("Cargo manifest directory");
    let root = Path::new(&manifest).ancestors()
        .find(|path| path.join("tools/build_info.py").is_file() && path.join("Cargo.toml").is_file())
        .expect("repository root containing tools/build_info.py");
    let output = Command::new("uv")
        .arg("run")
        .arg(root.join("tools/build_info.py"))
        .arg("--root").arg(&root)
        .arg("--cargo")
        .current_dir(&root)
        .output()
        .expect("Version generation requires uv; install the project tools with mise install");
    assert!(output.status.success(), "version-pioneer failed: {}", String::from_utf8_lossy(&output.stderr));
    print!("{}", String::from_utf8(output.stdout).expect("UTF-8 version metadata"));
    println!("cargo:rerun-if-changed={}", root.join("tools/rust_build_info.rs").display());
}
