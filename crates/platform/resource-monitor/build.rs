fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/darwin.c")
            .compile("terminal-resource-darwin");
        println!("cargo:rerun-if-changed=src/darwin.c");
    }
}
