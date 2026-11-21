# Android auth recovery

Reject an incorrect password, keep existing workspaces connected, mask and clear the failed secret, then correct credentials through the production page. Reload the saved connection and reconnect: Auto video-quality values must survive Godot's float-valued JSON read, the manager's hostname-refresh save and a bulk save without numeric type errors or changes to the other workspace.

Adapted from `remote authentication`. The shared implementation is `auth_recovery` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-auth-recovery --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-auth-recovery --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
