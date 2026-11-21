# Android prefix shortcuts

Verify the default Ctrl+A prefix with an external keyboard and with the on-screen
Ctrl button followed by IME text events. The next unmodified IME C must create a
remote tab. Also test a configured external-keyboard prefix, numeric navigation,
cancellation, invalid targets and focus loss.

Adapted from `prefix-shortcuts`. The shared implementation is `prefix_shortcuts` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-prefix-shortcuts --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-prefix-shortcuts --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
