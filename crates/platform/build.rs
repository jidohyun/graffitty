fn main() {
    #[cfg(feature = "clipboard")]
    if std::env::var("TARGET").unwrap_or_default().contains("apple-darwin") {
        let source = "src/clipboard_mime.mm";
        cc::Build::new()
            .cpp(true)
            .file(source)
            .flag("-fobjc-arc")
            .flag("-mmacosx-version-min=11.0")
            .compile("graffitty-clipboard");
        println!("cargo:rerun-if-changed={source}");
        println!("cargo:rustc-link-lib=framework=AppKit");
        println!("cargo:rustc-link-lib=framework=UniformTypeIdentifiers");
    }
}
