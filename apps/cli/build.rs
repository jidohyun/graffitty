#[path = "../../tools/rust_build_info.rs"]
mod build_info;

fn main() {
    build_info::emit();
    // The owner decodes inline images on its main thread.
    //
    // Windows' default 1 MiB stack can overflow in debug PNG decoding;
    // reserve the same 8 MiB available to a typical Unix main thread (pages
    // are committed on demand).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        println!("cargo:rustc-link-arg-bin=gft=/STACK:8388608");
    }
}
