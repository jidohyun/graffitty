# Android tab titles

Rename a tab using the real server CLI; preserve that name across OSC program titles and tab switching.

Adapted from `tab-titles`. The shared implementation is `tab_titles` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-tab-titles --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-tab-titles --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
