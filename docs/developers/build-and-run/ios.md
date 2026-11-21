# iOS and iPadOS builds

Build a **remote client** for ARM64 iPhones and iPads running **iOS 16+**.
A Graffitty server must run on another computer.

## Prepare the Mac

1. Install full **Xcode** and add your Apple developer account and signing team.
2. Install the repository's Rust, Zig, and Godot versions with `mise install`.
3. Install the matching Godot **`ios.zip` export template**.
4. Fetch the repository's DVC assets with `dvc pull`.
5. Run `mise run dev:build` to build the Mac extension used during asset import.

## Build and sign

```sh
export IOS_DEVELOPMENT_TEAM=YOUR_TEAM_ID
python3 tools/build_ios.py
```

Output goes to `build/ios/`. This produces a development-signed Debug app;
App Store packaging is not implemented.

| Task | Command |
| --- | --- |
| Rebuild only the native extension | `python3 tools/build_ios.py --native-only` |
| Export an Xcode project using the existing extension | `python3 tools/build_ios.py --skip-native --export-only` |
| Rebuild the app using the existing extension | `python3 tools/build_ios.py --skip-native` |

Build completion produces an archive/export; it is not yet device acceptance.

## Install on a device

1. Unlock and trust the device; enable Developer Mode where available.
2. Find its identifier:

   ```sh
   xcrun devicectl list devices # iOS 17+
   idevice_id -l                # iOS 16, connected by USB
   ```

3. Set `IOS_DEVICE_ID` locally, then install and launch:

   ```sh
   python3 tools/build_ios.py --skip-native --device "$IOS_DEVICE_ID"
   ```

For iOS 16, install the additional device tools first:

```sh
brew install ios-deploy libimobiledevice
```

The installer does not terminate an already-running app. iOS shutdown and
session survival still need device testing; do not assume a forced restart is harmless.

## Platform support

| Feature | Support |
| --- | --- |
| Rendering | Flat 2D by default; Metal on A11 or newer, Compatibility on older supported devices |
| Input | Native keyboard; Command shortcuts; clipboard images without photo-library access |
| Passwords | Keychain |
| Dictation | Microphone permission required; interruptions cancel capture |
| Browser video | Hardware H.264/HEVC, PNG fallback; no AV1 |

## Validate

Confirm launch and connection on the installed device before recording a result.

```sh
python3 -m unittest discover -s tests/tools -p test_build_ios.py -v
cargo test -p graffitty-dictation-audio --features device-capture
cargo test -p graffitty-chromium-video
```

The build script checks signing, deployment targets, permissions, and translated
permission prompts. Keep signing credentials and device identifiers outside Git.

**Still requires physical-device acceptance:** keyboard avoidance, CJK input,
rotation, safe areas, hardware modifiers, image paste, microphone interruptions,
video playback, and background/resume.

Use `tests/e2e/coverage.md` and its linked scenarios. A build, simulator run, or
successful install does not establish that these interactions work on a device.
