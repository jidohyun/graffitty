#!/usr/bin/env python3
"""Build the ARM64 Godot remote client using an installed Android SDK/NDK."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

from mise_tasks import android_sdk, godot
from android_ime import prepare_template

ROOT = Path(__file__).resolve().parent.parent
GODOT_ROOT = ROOT / "frontends/godot/project"


def run(*args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def release_signing():
    """Godot's release-keystore variables from a Gradle-style properties file
    (storeFile, storePassword, keyAlias, keyPassword) named by
    GRAFFITTY_ANDROID_KEYSTORE. The keystore and its secrets stay outside the repo."""
    location = os.environ.get("GRAFFITTY_ANDROID_KEYSTORE")
    if not location:
        sys.exit("Set GRAFFITTY_ANDROID_KEYSTORE to the release keystore's .properties file")
    values = {}
    for line in Path(location).expanduser().read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and not key.lstrip().startswith("#"):
            values[key.strip()] = value.strip()
    missing = [key for key in ("storeFile", "storePassword", "keyAlias", "keyPassword") if not values.get(key)]
    if missing:
        sys.exit(f"Android keystore properties lack: {', '.join(missing)}")
    if values["storePassword"] != values["keyPassword"]:
        sys.exit("Godot signs with one password: the store and key passwords must match")
    store = Path(values["storeFile"]).expanduser()
    if not store.is_file():
        sys.exit(f"Missing Android release keystore: {store}")
    return {"GODOT_ANDROID_KEYSTORE_RELEASE_PATH": str(store),
            "GODOT_ANDROID_KEYSTORE_RELEASE_USER": values["keyAlias"],
            "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD": values["storePassword"]}


def main():
    signing = release_signing()
    run("uv", "run", "tools/build_info.py")
    sdk = android_sdk()
    ndk = Path(os.environ.get("ANDROID_NDK_HOME", str(sdk / "ndk/28.1.13356709")))
    host = "windows-x86_64" if os.name == "nt" else ("darwin-x86_64" if sys.platform == "darwin" else "linux-x86_64")
    bin_dir = ndk / "toolchains/llvm/prebuilt" / host / "bin"
    wrapper = ".cmd" if os.name == "nt" else ""
    clang = bin_dir / ("aarch64-linux-android28-clang" + wrapper)
    clangxx = bin_dir / ("aarch64-linux-android28-clang++" + wrapper)
    if not clang.exists():
        sys.exit(f"Install Android NDK 28.1.13356709, or set ANDROID_NDK_HOME: {ndk}")
    # Match the current compiler's numbered rustup toolchain, including when
    # Homebrew supplies cargo/rustc and the default rustup alias is incomplete.
    version = subprocess.check_output(["rustc", "--version"], text=True).split()[1]
    toolchain = os.environ.get("ANDROID_RUST_TOOLCHAIN", version)
    run("rustup", "target", "add", "--toolchain", toolchain, "aarch64-linux-android")
    compiler = subprocess.check_output(["rustup", "which", "--toolchain", toolchain, "rustc"], text=True).strip()
    env = dict(os.environ, RUSTC=compiler, ANDROID_NDK_HOME=str(ndk), ANDROID_PLATFORM="android-28",
               CC_aarch64_linux_android=str(clang),
               CXX_aarch64_linux_android=str(clangxx),
               # rquickjs-sys (crates/mods) has no pregenerated Android bindings;
               # its bindgen feature generates them with the NDK's own libclang.
               LIBCLANG_PATH=str(bin_dir.parent / "lib"),
               BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android=f"--sysroot={bin_dir.parent / 'sysroot'}",
               AR_aarch64_linux_android=str(bin_dir / ("llvm-ar.exe" if os.name == "nt" else "llvm-ar")),
               CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=str(clang))
    run("rustup", "run", toolchain, "cargo", "build", "--release", "--locked",
        "--target", "aarch64-linux-android", "--manifest-path", "frontends/godot/extension/Cargo.toml", env=env)
    shutil.copy2(ROOT / "frontends/godot/extension/target/aarch64-linux-android/release/libgraffitty.so",
                 GODOT_ROOT / "addons/graffitty/bin/libgraffitty.android.arm64.so")
    output = ROOT / "build/android/graffitty.apk"
    output.parent.mkdir(parents=True, exist_ok=True)
    # Stage shared UI sources without importing multi-gigabyte desktop worlds
    # or treating Rust .obj build artifacts as meshes.
    project = output.parent / "project"
    # Export only current sources. Reusing this tree retains renamed extensions,
    # deleted scripts and their Godot import metadata in the next APK.
    if project.exists():
        shutil.rmtree(project)
    for directory in ["scenes", "config", "presets", "mods", "graffitty", "addons/graffitty", "addons/source_assets", "assets/icons", "assets/branding/exports"]:
        shutil.copytree(GODOT_ROOT / directory, project / directory, dirs_exist_ok=True)
    text, plugin_sections = re.subn(
        r"(?ms)^\[editor_plugins\]\n.*?(?=^\[|\Z)",
        '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/source_assets/plugin.cfg")\n\n',
        (GODOT_ROOT / "project.godot").read_text(),
    )
    if plugin_sections != 1:
        sys.exit("Expected one editor_plugins section for Android export")
    (project / "project.godot").write_text(text)
    presets = (GODOT_ROOT / "export_presets.cfg").read_text()
    # Runtime source ports and the bundled commercial audio keep their notices.
    # Bundled mods are plain JS/JSON/SVG, which Godot exports only when the
    # filter names them; a stale preset must not ship manifests without code.
    required = ["mods/*.js", "mods/*.json", "mods/*.svg", "scenes/agents-LICENSE.txt", "scenes/sounds/README.md"]
    def include(match: re.Match) -> str:
        entries = [entry for entry in match.group(1).split(",") if entry]
        entries += [entry for entry in required if entry not in entries]
        return 'include_filter="' + ",".join(entries) + '"'
    presets, filters = re.subn(r'(?m)^include_filter="([^"]*)"', include, presets)
    if filters == 0:
        sys.exit("Expected an include_filter in export_presets.cfg")
    # Local export presets are ignored by git; every build needs permission
    # for the recording-start and keyboard-drag haptics.
    presets = re.sub(r"(?m)^permissions/vibrate=.*\n?", "", presets)
    presets = presets.replace("[preset.0.options]", "[preset.0.options]\n\npermissions/vibrate=true", 1)
    launch = godot()
    # The client is a signed release; staged test tools still export debug APKs.
    for kind in ("debug", "release"):
        template = prepare_template(sdk, launch, output.parent / f"terminal-ime-{kind}.apk", kind)
        line = f'custom_template/{kind}="{template.as_posix()}"'
        presets, count = re.subn(rf'(?m)^custom_template/{kind}=.*$', line, presets)
        if not count:
            presets = presets.replace("[preset.0.options]\n", f"[preset.0.options]\n\n{line}\n", 1)
    (project / "export_presets.cfg").write_text(presets)
    # Godot can exit successfully after script parse/compile errors. Never
    # package a broken client merely because the import process returned zero.
    imported = subprocess.run([launch, "--headless", "--editor", "--path", str(project), "--import"],
                              cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(imported.stdout, end="")
    if imported.returncode or "SCRIPT ERROR:" in imported.stdout:
        sys.exit("Android project import failed; APK export aborted")
    run(launch, "--headless", "--path", str(project), "--export-release", "Android", str(output),
        env=dict(os.environ, **signing))
    # Imported texture resources do not retain source SVG/PNG files by default.
    # These providers use FileAccess for DPI rendering, so verify actual APK bytes.
    with zipfile.ZipFile(output) as apk:
        if any(name.startswith("assets/worlds/") for name in apk.namelist()):
            sys.exit("Android APK must contain only the built-in Flat and Flat 2D worlds")
        catalog = "config/localization.json"
        if apk.read("assets/" + catalog) != (GODOT_ROOT / catalog).read_bytes():
            sys.exit("Android APK localization catalog differs from source")
        for attribution in ["scenes/icons/FONT-AWESOME-LICENSE", "scenes/icons/LUCIDE-LICENSE", "scenes/icons/README.md"]:
            if apk.read("assets/" + attribution) != (GODOT_ROOT / attribution).read_bytes():
                sys.exit(f"Android APK icon attribution differs: {attribution}")
        for directory in ["scenes/icons", "assets/icons"]:
            for icon in (GODOT_ROOT / directory).rglob("*"):
                if icon.suffix not in {".svg", ".png"}:
                    continue
                name = "assets/" + icon.relative_to(GODOT_ROOT).as_posix()
                if apk.read(name) != icon.read_bytes():
                    sys.exit(f"Android APK icon source differs: {name}")
    print(output)


if __name__ == "__main__":
    main()
