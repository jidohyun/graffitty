fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        println!("cargo:rerun-if-changed=src/shared_windows.cpp");
        println!("cargo:rerun-if-changed=src/windows_surface.h");
        println!("cargo:rerun-if-changed=include/windows_adapter.h");
        println!("cargo:rerun-if-changed=include/frame_protocol_windows.h");
        cc::Build::new()
            .cpp(true)
            .static_crt(true)
            .debug(false)
            .std("c++20")
            .file("src/shared_windows.cpp")
            .compile("graffitty-shared-windows");
        for library in ["d3d11", "d3d12", "dxgi", "bcrypt", "advapi32"] {
            println!("cargo:rustc-link-lib={library}");
        }
    }
    println!("cargo:rustc-check-cfg=cfg(chromium_video)");
    let apple = matches!(std::env::var("CARGO_CFG_TARGET_OS").as_deref(), Ok("ios" | "macos"));
    if apple {
        println!("cargo:rerun-if-changed=src/apple_decode.m");
        println!("cargo:rerun-if-changed=src/yuv420.h");
        println!("cargo:rerun-if-env-changed=IPHONEOS_DEPLOYMENT_TARGET");
        let mut adapter = cc::Build::new();
        adapter.file("src/apple_decode.m").flag("-fobjc-arc");
        if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios") {
            // iOS 16 is the minimum (tools/build_ios.py sets it). The adapter
            // guards newer APIs (the iOS 17 hardware-decoder keys) with
            // @available; fail on any unguarded API newer than the target.
            if std::env::var_os("IPHONEOS_DEPLOYMENT_TARGET").is_none() {
                // SAFETY: build scripts are single-threaded at this point.
                unsafe { std::env::set_var("IPHONEOS_DEPLOYMENT_TARGET", "16.0") };
            }
            adapter.flag("-Werror=unguarded-availability-new");
        }
        // Also built on macOS so the exact adapter can have hardware roundtrip tests.
        adapter.compile("graffitty-apple-decode");
        for framework in ["Foundation", "VideoToolbox", "CoreMedia", "CoreVideo"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios") { return; }
    }
    println!("cargo:rerun-if-changed=src/codec.c");
    println!("cargo:rerun-if-changed=src/android.c");
    println!("cargo:rerun-if-changed=src/yuv420.h");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        cc::Build::new()
            .file("src/android.c")
            .compile("graffitty-chromium-video");
        println!("cargo:rustc-link-lib=mediandk");
        println!("cargo:rustc-link-lib=log");
        println!("cargo:rustc-cfg=chromium_video");
        return;
    }
    println!("cargo:rerun-if-env-changed=GRAFFITTY_VIDEO_REQUIRED");
    let root =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../..");
    let prefix = root
        .join(".cache/chromium-video")
        .join(std::env::var("TARGET").unwrap());
    let stamp = prefix.join(".version");
    let bundled = stamp.is_file();
    // A missing watched file makes Cargo rebuild on every invocation. Watch
    // an existing, target-specific directory until the optional bundle is
    // installed, then watch its version stamp.
    //
    // This also detects installation after a build that used system FFmpeg or
    // had no video support.
    if !bundled {
        std::fs::create_dir_all(&prefix).expect("create chromium video cache directory");
    }
    let watched = if bundled { &stamp } else { &prefix };
    println!("cargo:rerun-if-changed={}", watched.display());
    if matches!(
        std::env::var("CARGO_CFG_TARGET_OS").as_deref(),
        Ok("macos" | "windows" | "linux")
    ) && !bundled
    {
        panic!(
            "Desktop chromium video requires the pinned static FFmpeg build: run python tools/build_chromium_video.py"
        );
    }
    if bundled {
        // Build scripts execute before compilation and have no other threads.
        unsafe {
            std::env::set_var("PKG_CONFIG_PATH", prefix.join("lib/pkgconfig"));
            std::env::set_var("PKG_CONFIG_LIBDIR", prefix.join("lib/pkgconfig"));
            std::env::set_var("PKG_CONFIG_ALLOW_CROSS", "1");
        }
    }
    let libraries: Result<Vec<_>, _> = ["libavcodec", "libavutil", "libswscale"]
        .iter()
        .map(|name| {
            pkg_config::Config::new()
                .statik(bundled)
                .cargo_metadata(false)
                .probe(name)
        })
        .collect();
    match libraries {
        Ok(libraries) => {
            for name in ["libavcodec", "libavutil", "libswscale"] {
                pkg_config::Config::new()
                    .statik(bundled)
                    .probe(name)
                    .unwrap();
            }
            let mut build = cc::Build::new();
            build.file("src/codec.c");
            if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
                build.static_crt(true);
                println!("cargo:rerun-if-changed=src/video_windows.cpp");
                let mut gpu = cc::Build::new();
                gpu.cpp(true)
                    .static_crt(true)
                    .std("c++20")
                    .file("src/video_windows.cpp");
                for lib in &libraries {
                    for path in &lib.include_paths {
                        gpu.include(path);
                    }
                }
                gpu.compile("graffitty-windows-video");
            }
            for lib in &libraries {
                for path in &lib.include_paths {
                    build.include(path);
                }
            }
            let linux = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux");
            if linux {
                build.define("GRAFFITTY_VA_LOADER", None);
            }
            build.compile("graffitty-chromium-video");
            if linux {
                // FFmpeg's VA-API code calls libva, which the bundled FFmpeg
                // does not link: these definitions load the system's libva on
                // demand. Whole-archive keeps them regardless of link order.
                println!("cargo:rerun-if-changed=src/va_loader_linux.c");
                cc::Build::new()
                    .file("src/va_loader_linux.c")
                    .flag("-fvisibility=hidden")
                    .link_lib_modifier("+whole-archive")
                    .compile("graffitty-va-loader");
                println!("cargo:rustc-link-lib=pthread");
                // Both GPU import backends load their drivers at runtime.
                println!("cargo:rerun-if-changed=src/surface_linux.cpp");
                println!("cargo:rerun-if-changed=src/vulkan_readback.cpp");
                println!("cargo:rerun-if-changed=src/vulkan_readback.h");
                println!("cargo:rerun-if-changed=include/linux_vulkan.h");
                println!("cargo:rerun-if-changed=src/scale_linux.ptx");
                println!("cargo:rerun-if-changed=include/frame_protocol_linux.h");
                let mut gpu = cc::Build::new();
                gpu.cpp(true)
                    .std("c++20")
                    .flag("-Wno-missing-field-initializers")
                    .file("src/surface_linux.cpp")
                    .file("src/vulkan_readback.cpp");
                for lib in &libraries {
                    for path in &lib.include_paths {
                        gpu.include(path);
                    }
                }
                gpu.compile("graffitty-linux-surface");
                println!("cargo:rustc-link-lib=dl");
            }
            if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
                println!("cargo:rustc-link-lib=framework=VideoToolbox");
                println!("cargo:rustc-link-lib=framework=IOSurface");
                println!("cargo:rustc-link-lib=framework=Metal");
                println!("cargo:rustc-link-lib=framework=MetalPerformanceShaders");
                println!("cargo:rustc-link-lib=bsm");
                println!("cargo:rustc-link-lib=framework=Foundation");
                println!("cargo:rerun-if-changed=src/surface.m");
                println!("cargo:rerun-if-changed=src/shared_gpu.m");
                cc::Build::new()
                    .file("src/surface.m")
                    .file("src/shared_gpu.m")
                    .compile("graffitty-chromium-surface");
            }
            println!("cargo:rustc-cfg=chromium_video");
        }
        Err(error) => {
            if std::env::var("GRAFFITTY_VIDEO_REQUIRED").as_deref() == Ok("1") {
                panic!("Hardware chromium video requires FFmpeg development libraries: {error}");
            }
            println!(
                "cargo:warning=Hardware chromium video unavailable: install FFmpeg development libraries or configure target PKG_CONFIG_LIBDIR."
            );
        }
    }
}
