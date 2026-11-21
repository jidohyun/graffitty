#!/usr/bin/env python3
"""Build the shared Godot remote client for iOS/iPadOS 16 (macOS + Xcode)."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "frontends/godot/project"
OUTPUT = ROOT / "build/ios"
MIN_IOS = "16.0"
TARGET = "aarch64-apple-ios"
BUNDLE_ID = "app.graffitty.client"
IOS_LIBRARY = PROJECT / "addons/graffitty/bin/libgraffitty.ios.arm64.dylib"
# The headless import runs the editor on this Mac, so it loads the host extension.
HOST_LIBRARY = PROJECT / "addons/graffitty/bin/libgraffitty.macos.dylib"
# Remote-client resources. Every res:// directory the client loads must be listed here.
STAGE_DIRECTORIES = ["scenes", "config", "presets", "mods", "graffitty", "addons/graffitty",
                     "addons/source_assets", "assets/icons", "assets/branding/exports"]
# Catalog messages (English source text) shown in the system permission prompts.
LOCAL_NETWORK_MESSAGE = "Graffitty uses your local network to connect to the Graffitty servers you add, so you can view and control your terminals."
MICROPHONE_MESSAGE = "Graffitty records from the microphone only while you dictate, and sends the audio to your configured dictation service to turn it into text."
# Camera/photo access has no iOS adapter. Dictation supplies its own consent text.
UNUSED_PERMISSIONS = ("NSCameraUsageDescription", "NSPhotoLibraryUsageDescription")
MACH_O_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def run(*args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read(path):
    return Path(path).read_text(encoding="utf-8")


def write(path, text):
    Path(path).write_text(text, encoding="utf-8")


def native_environment():
    sdk = output("xcrun", "--sdk", "iphoneos", "--show-sdk-path")
    developer = output("xcode-select", "-p")
    toolchain = os.environ.get("IOS_RUST_TOOLCHAIN", output("rustc", "--version").split()[1])
    compiler = output("rustup", "which", "--toolchain", toolchain, "rustc")
    env = dict(os.environ, RUSTC=compiler, SDKROOT=sdk, IPHONEOS_DEPLOYMENT_TARGET=MIN_IOS,
               LIBCLANG_PATH=f"{developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib",
               BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios=f"--sysroot={sdk} -miphoneos-version-min={MIN_IOS}")
    return toolchain, env


def check_build_version(details, name):
    """Require every Mach-O slice to be an iOS binary whose minimum OS is exactly MIN_IOS."""
    platforms = re.findall(r"^\s*platform\s+(\S+)", details, re.M)
    minimums = re.findall(r"^\s*minos\s+(\S+)", details, re.M)
    if not platforms or len(platforms) != len(minimums):
        raise RuntimeError(f"{name} has no LC_BUILD_VERSION:\n{details}")
    if any(platform != "IOS" for platform in platforms) or any(m not in (MIN_IOS, MIN_IOS + ".0") for m in minimums):
        raise RuntimeError(f"{name} does not target iOS {MIN_IOS}:\n{details}")


def require_ios_target(binary):
    # Verify the actual Mach-O load command, not just the requested Cargo env.
    check_build_version(output("xcrun", "vtool", "-show-build", str(binary)), Path(binary).name)


def is_mach_o(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as file:
        return file.read(4) in MACH_O_MAGIC


def build_native():
    toolchain, env = native_environment()
    run("rustup", "target", "add", "--toolchain", toolchain, TARGET)
    run("rustup", "run", toolchain, "cargo", "build", "--locked", "--release",
        "--target", TARGET, "--manifest-path", "frontends/godot/extension/Cargo.toml", env=env)
    library = ROOT / f"frontends/godot/extension/target/{TARGET}/release/libgraffitty.dylib"
    shutil.copy2(library, IOS_LIBRARY)


def preset_option(preset, key):
    values = re.findall(rf'(?m)^{re.escape(key)}=(.*)$', preset)
    if len(values) != 1:
        raise RuntimeError(f"Expected exactly one {key} in the iOS export preset")
    return values[0].strip('"')


def export_preset(team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Set IOS_DEVELOPMENT_TEAM (10-character Apple team ID), or pass --team")
    preset = read(ROOT / "frontends/godot/ios/export_presets.cfg")
    # The script and preset must agree; there is one source of truth for each.
    if preset_option(preset, "application/min_ios_version") != MIN_IOS:
        raise RuntimeError(f"iOS export preset does not request iOS {MIN_IOS}")
    if preset_option(preset, "application/bundle_identifier") != BUNDLE_ID:
        raise RuntimeError(f"iOS export preset bundle identifier is not {BUNDLE_ID}")
    if preset_option(preset, "application/app_store_team_id") != "":
        raise RuntimeError("The source iOS preset must not contain a team ID")
    return preset.replace('application/app_store_team_id=""', f'application/app_store_team_id="{team}"', 1)


def stage_project(team):
    # Never edit the shared project's export presets or keep obsolete staged files.
    stage = OUTPUT / "project"
    if stage.exists():
        shutil.rmtree(stage)
    for directory in STAGE_DIRECTORIES:
        shutil.copytree(PROJECT / directory, stage / directory, dirs_exist_ok=True)
    source = read(PROJECT / "project.godot")
    source, count = re.subn(r'(?ms)^\[editor_plugins\]\n.*?(?=^\[|\Z)',
                          '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/source_assets/plugin.cfg")\n\n', source)
    if count != 1:
        raise RuntimeError("Expected one editor_plugins section")
    write(stage / "project.godot", source)
    write(stage / "export_presets.cfg", export_preset(team))
    return stage


def permission_strings(catalog, locale):
    """The localized system-permission prompts for one locale (InfoPlist.strings text)."""
    local_network = catalog["messages"][LOCAL_NETWORK_MESSAGE][locale]
    microphone = catalog["messages"][MICROPHONE_MESSAGE][locale]
    return ('NSLocalNetworkUsageDescription = ' + json.dumps(local_network, ensure_ascii=False) + ';\n'
            + 'NSMicrophoneUsageDescription = ' + json.dumps(microphone, ensure_ascii=False) + ';\n')


def localize_permissions(project):
    """Bundle the existing eleven translations for the system permission prompts."""
    catalog = json.loads(read(PROJECT / "config/localization.json"))
    pbx = project / "project.pbxproj"
    text = read(pbx)
    if "localizations/" in text:
        raise RuntimeError("Xcode project already contains permission localizations")
    files, references, resources = [], [], []
    for locale in catalog["locales"]:
        folder = project.parent / "localizations" / f"{locale}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        write(folder / "InfoPlist.strings", permission_strings(catalog, locale))
        ref = hashlib.sha256(f"ios-locale-ref:{locale}".encode()).hexdigest()[:24].upper()
        build = hashlib.sha256(f"ios-locale-build:{locale}".encode()).hexdigest()[:24].upper()
        files.append(f'\t\t{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};\n')
        references.append(f'\t\t{ref} = {{isa = PBXFileReference; lastKnownFileType = folder; path = "localizations/{locale}.lproj"; sourceTree = SOURCE_ROOT; }};\n')
        resources.append(f'\t\t\t\t{build},\n')
    for section, entries in [("PBXBuildFile", files), ("PBXFileReference", references)]:
        marker = f"/* End {section} section */"
        if text.count(marker) != 1:
            raise RuntimeError(f"Expected one Xcode {section} section")
        text = text.replace(marker, "".join(entries) + marker)
    text, count = re.subn(r'(isa = PBXResourcesBuildPhase;.*?files = \(\n)',
                         lambda match: match[1] + "".join(resources), text, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("Expected an Xcode resources phase")
    write(pbx, text)


LAUNCH_WALL = "assets/branding/exports/graffitty-icon-android-background.png"
LAUNCH_LOGO_POINTS = 288  # Android's launch cover draws the logo at 288dp.
LAUNCH_STORYBOARD = """<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="16097" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="01J-lp-oVM">
    <device id="retina6_1" orientation="portrait" appearance="light"/>
    <dependencies>
        <deployment identifier="iOS"/>
        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="16087"/>
        <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
    </dependencies>
    <scenes>
        <scene sceneID="EHf-IW-A2E">
            <objects>
                <viewController id="01J-lp-oVM" sceneMemberID="viewController">
                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
                        <rect key="frame" x="0.0" y="0.0" width="414" height="896"/>
                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                        <subviews>
                            <imageView userInteractionEnabled="NO" contentMode="scaleToFill" image="LaunchWall" translatesAutoresizingMaskIntoConstraints="NO" id="gW1-wa-LL0">
                                <rect key="frame" x="0.0" y="0.0" width="414" height="896"/>
                            </imageView>
                            <imageView userInteractionEnabled="NO" contentMode="scaleAspectFit" image="SplashImage" translatesAutoresizingMaskIntoConstraints="NO" id="tjZ-vn-Lsv">
                                <rect key="frame" x="63" y="304" width="@LOGO@" height="@LOGO@"/>
                                <constraints>
                                    <constraint firstAttribute="width" constant="@LOGO@" id="lW0-0a-007"/>
                                    <constraint firstAttribute="height" constant="@LOGO@" id="lH0-0a-008"/>
                                </constraints>
                            </imageView>
                        </subviews>
                        <color key="backgroundColor" red="0.02" green="0.02" blue="0.03" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
                        <constraints>
                            <constraint firstItem="gW1-wa-LL0" firstAttribute="top" secondItem="Ze5-6b-2t3" secondAttribute="top" id="wTp-0a-001"/>
                            <constraint firstItem="gW1-wa-LL0" firstAttribute="bottom" secondItem="Ze5-6b-2t3" secondAttribute="bottom" id="wBt-0a-002"/>
                            <constraint firstItem="gW1-wa-LL0" firstAttribute="leading" secondItem="Ze5-6b-2t3" secondAttribute="leading" id="wLd-0a-003"/>
                            <constraint firstItem="gW1-wa-LL0" firstAttribute="trailing" secondItem="Ze5-6b-2t3" secondAttribute="trailing" id="wTr-0a-004"/>
                            <constraint firstItem="tjZ-vn-Lsv" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="lCx-0a-005"/>
                            <constraint firstItem="tjZ-vn-Lsv" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="lCy-0a-006"/>
                        </constraints>
                    </view>
                </viewController>
                <placeholder placeholderIdentifier="IBFirstResponder" id="iYj-Kq-Ea1" userLabel="First Responder" sceneMemberID="firstResponder"/>
            </objects>
        </scene>
    </scenes>
    <resources>
        <image name="LaunchWall" width="432" height="432"/>
        <image name="SplashImage" width="216" height="216"/>
    </resources>
</document>
""".replace("@LOGO@", str(LAUNCH_LOGO_POINTS))


def launch_screen(exported):
    """Match Android's launch cover: the icon wall stretched full-screen, the logo centered at 288pt.

    Godot's storyboard only supports one image on a solid color, so the export's
    logo (SplashImage, from the preset) gets the wall added behind it here.
    """
    app = exported / "Graffitty"
    wall = app / "Images.xcassets/LaunchWall.imageset"
    wall.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(PROJECT / LAUNCH_WALL, wall / "wall.png")
    write(wall / "Contents.json", json.dumps({
        "images": [{"idiom": "universal", "filename": "wall.png"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    if not (app / "Images.xcassets/SplashImage.imageset").is_dir():
        raise RuntimeError("Godot did not export the launch logo")
    storyboard = app / "Launch Screen.storyboard"
    if not storyboard.is_file():
        raise RuntimeError("Godot did not export a launch storyboard")
    write(storyboard, LAUNCH_STORYBOARD)


def prune_unused_permissions(info):
    for key in UNUSED_PERMISSIONS:
        if not info.get(key):
            info.pop(key, None)
    return info


def pin_framework_deployment_target(exported):
    """Godot stamps GDExtension frameworks with its own MinimumOSVersion; match the app."""
    manifests = sorted((exported / "Graffitty/dylibs").rglob("*.framework/Info.plist"))
    if not manifests:
        raise RuntimeError("Godot did not embed the extension as a framework")
    for manifest in manifests:
        info = plistlib.loads(manifest.read_bytes())
        info["MinimumOSVersion"] = MIN_IOS
        manifest.write_bytes(plistlib.dumps(info))
    return manifests


def verify_export(exported, project):
    targets = re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;\s]+);", read(project / "project.pbxproj"))
    if not targets or set(targets) != {MIN_IOS}:
        raise RuntimeError(f"Xcode project deployment targets are {sorted(set(targets))}, not {MIN_IOS}")
    info = plistlib.loads((exported / "Graffitty/Graffitty-Info.plist").read_bytes())
    for key in ("NSLocalNetworkUsageDescription", "NSMicrophoneUsageDescription"):
        if not info.get(key):
            raise RuntimeError(f"Exported Info.plist is missing {key}")
    for key in UNUSED_PERMISSIONS:
        if key in info:
            raise RuntimeError(f"Exported Info.plist declares unused permission {key}")
    for manifest in (exported / "Graffitty/dylibs").rglob("*.framework/Info.plist"):
        if plistlib.loads(manifest.read_bytes()).get("MinimumOSVersion") != MIN_IOS:
            raise RuntimeError(f"{manifest} does not request iOS {MIN_IOS}")


def signing_team(app):
    result = subprocess.run(["codesign", "-dv", str(app)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
    match = re.search(r"^TeamIdentifier=(\S+)$", result.stdout, re.M)
    return match[1] if match else None


def verify_app(app, team):
    """Check the signed bundle itself: identity, deployment target, binaries, localizations."""
    run("codesign", "--verify", "--deep", "--strict", str(app))
    if signing_team(app) != team:
        raise RuntimeError(f"App is not signed by team {team}")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("MinimumOSVersion") != MIN_IOS:
        raise RuntimeError(f"App minimum OS is not {MIN_IOS}")
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError(f"App bundle identifier is not {BUNDLE_ID}")
    for key in UNUSED_PERMISSIONS:
        if key in info:
            raise RuntimeError(f"App declares unused permission {key}")
    binaries = sorted(path for path in app.rglob("*") if is_mach_o(path))
    if app / info["CFBundleExecutable"] not in binaries or not any("Frameworks" in path.parts for path in binaries):
        raise RuntimeError("App is missing its executable or the embedded extension")
    for binary in binaries:
        require_ios_target(binary)
    for manifest in app.glob("Frameworks/*.framework/Info.plist"):
        if plistlib.loads(manifest.read_bytes()).get("MinimumOSVersion") != MIN_IOS:
            raise RuntimeError(f"{manifest.parent.name} does not request iOS {MIN_IOS}")
    catalog = json.loads(read(PROJECT / "config/localization.json"))
    for locale in catalog["locales"]:
        strings = app / f"{locale}.lproj/InfoPlist.strings"
        if not strings.is_file() or read(strings) != permission_strings(catalog, locale):
            raise RuntimeError(f"App is missing the {locale} permission translations")
    return info


def checked_godot(launch, *args):
    result = subprocess.run([launch, *args], cwd=ROOT, text=True, encoding="utf-8", errors="replace",
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    if result.returncode or "SCRIPT ERROR:" in result.stdout or "ERROR:" in result.stdout:
        raise RuntimeError("Godot import/export failed; iOS build aborted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", default=os.environ.get("IOS_DEVELOPMENT_TEAM", ""))
    parser.add_argument("--native-only", action="store_true", help="Build and verify only the ARM64 extension")
    parser.add_argument("--skip-native", action="store_true", help="Reuse the existing iOS extension")
    parser.add_argument("--export-only", action="store_true", help="Generate the Xcode project without building it")
    parser.add_argument("--device", help="Install and launch on this connected device ID (never committed)")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("iOS exports require macOS and Xcode")
    if args.native_only and (args.skip_native or args.export_only or args.device):
        parser.error("--native-only cannot be combined with export/install options")
    if args.export_only and args.device:
        parser.error("--device requires an app build, not --export-only")
    if not args.native_only:
        export_preset(args.team)  # Fail before compiling if signing configuration is absent.
        if not HOST_LIBRARY.is_file():
            raise RuntimeError("Godot's headless import needs the host extension; run `mise run dev:build` first")
    if not args.skip_native:
        build_native()
    if not IOS_LIBRARY.is_file():
        raise RuntimeError("Missing iOS extension; run without --skip-native")
    require_ios_target(IOS_LIBRARY)
    if args.native_only:
        return
    from mise_tasks import godot
    run("uv", "run", "tools/build_info.py")
    stage = stage_project(args.team)
    launch = godot()
    checked_godot(launch, "--headless", "--editor", "--path", str(stage), "--import")
    exported = OUTPUT / "export"
    if exported.exists():
        shutil.rmtree(exported)
    exported.mkdir(parents=True)
    checked_godot(launch, "--headless", "--path", str(stage), "--export-debug", "iOS", str(exported / "Graffitty.zip"))
    project = exported / "Graffitty.xcodeproj"
    if not project.exists():
        raise RuntimeError(f"Godot did not produce {project}")
    localize_permissions(project)
    pin_framework_deployment_target(exported)
    launch_screen(exported)
    info_path = exported / "Graffitty/Graffitty-Info.plist"
    info = prune_unused_permissions(plistlib.loads(info_path.read_bytes()))
    info_path.write_bytes(plistlib.dumps(info))
    verify_export(exported, project)
    if args.export_only:
        print(f"Open {project} in Xcode; deployment target is iOS {MIN_IOS}.")
        return
    app = OUTPUT / "derived/Build/Products/Debug-iphoneos/Graffitty.app"
    if app.exists():
        shutil.rmtree(app)  # Verify this build, not a stale bundle.
    run("xcodebuild", "-project", str(project), "-scheme", "Graffitty", "-configuration", "Debug",
        "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", str(OUTPUT / "derived"),
        "-allowProvisioningUpdates", f"DEVELOPMENT_TEAM={args.team}", "CODE_SIGN_STYLE=Automatic",
        f"IPHONEOS_DEPLOYMENT_TARGET={MIN_IOS}", "build")
    verify_app(app, args.team)
    print(f"Built {app} (minimum iOS {MIN_IOS})")
    if args.device:
        install(args.device, app)


def core_device(device):
    """True when devicectl can pair with the device (iOS 17+); older iOS is reached by UDID over usbmux."""
    listing = json.loads(output("xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", "-"))
    for entry in listing["result"]["devices"]:
        if device in (entry.get("identifier"), entry.get("hardwareProperties", {}).get("udid")):
            return entry.get("connectionProperties", {}).get("pairingState") != "unsupported"
    return False


def install(device, app):
    if core_device(device):
        run("xcrun", "devicectl", "device", "install", "app", "--device", device, str(app))
        run("xcrun", "devicectl", "device", "process", "launch", "--device", device, BUNDLE_ID)
    else:
        if not (shutil.which("ios-deploy") and shutil.which("idevicedebug")):
            raise RuntimeError("Devices before iOS 17 need ios-deploy and libimobiledevice (brew install ios-deploy libimobiledevice)")
        run("ios-deploy", "--id", device, "--bundle", str(app))
        # Launch through debugserver and detach; ios-deploy's lldb launch traps the app if lldb exits uncleanly.
        usb = device in output("idevice_id", "-l").split()
        run("idevicedebug", *([] if usb else ["--network"]), "--udid", device, "--detach", "run", BUNDLE_ID)


if __name__ == "__main__":
    main()
