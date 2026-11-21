# Android pane controls

Tap right/below split buttons with the centered pointer, split an unfocused pane, verify input isolation, close only the new pane.

Adapted from `new-terminal-window`. The shared implementation is `pane_controls` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-pane-controls --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-pane-controls --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
