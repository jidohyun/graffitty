# Android messages copy

Long-press the intentional Unicode diagnostic, use Android’s native Select all and Copy actions, and verify the full text reaches the clipboard. Open log must open an in-app native selectable log viewer. Close it, dismiss the panel, and verify no stale shortcut interception. Focusing a connection footer button during keyboard layout changes must not produce a scroll-ancestor error.

Adapted from `messages-copy`. The shared implementation is `messages_copy` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while native text selection and its contextual toolbar are exercised through UIAutomator on Android. A fresh standalone server owns every terminal, chromium and graph in this case.

The native log viewer must use translated title and Close labels without accessing Godot nodes from Android's UI thread. Opening and closing it must leave the diagnostic/error log empty apart from the intentional fixture. The harness reads Select all and Copy from Android's localized resources and targets the dialog's positive button by resource ID, so the device language stays unchanged.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-messages-copy --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-messages-copy --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
