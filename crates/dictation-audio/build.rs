fn main() {
    println!("cargo:rerun-if-changed=src/ios_audio.m");
    println!("cargo:rerun-if-env-changed=IPHONEOS_DEPLOYMENT_TARGET");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios")
        && std::env::var_os("CARGO_FEATURE_DEVICE_CAPTURE").is_some()
    {
        // iOS 16 is the minimum (tools/build_ios.py sets it); keep a bare
        // `cargo check --target` from compiling the adapter for an older OS.
        if std::env::var_os("IPHONEOS_DEPLOYMENT_TARGET").is_none() {
            // SAFETY: build scripts are single-threaded at this point.
            unsafe { std::env::set_var("IPHONEOS_DEPLOYMENT_TARGET", "16.0") };
        }
        cc::Build::new()
            .file("src/ios_audio.m")
            .flag("-fobjc-arc")
            .flag("-Werror=unguarded-availability-new")
            .compile("graffitty-ios-audio");
        for framework in ["AVFoundation", "Foundation"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }
}
