# Android bracketed paste

Paste Unicode and newlines into a real raw PTY; require exact bracketed-paste markers and payload with no duplicated bytes.

The same scenario supplies a PNG larger than one command packet through the
native image entry point. The server PTY reads the completed file and verifies
its SHA-256, one quoted path, and no synthesized Enter. This covers shared
image validation, chunking and terminal delivery; it does not exercise an OS
clipboard or establish that an agent recognized the image. Physical clipboard
and keyboard acceptance is specified in `tests/e2e/input.md` (IN-09).

Adapted from `terminal-input`. The shared implementation is `bracketed_paste` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-bracketed-paste --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-bracketed-paste --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
