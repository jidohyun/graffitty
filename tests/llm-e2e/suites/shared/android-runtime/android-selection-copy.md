# Android selection copy

Use Android double-tap-and-drag to select multiline Korean and emoji in a streamed terminal, then copy the actual selection.

The native terminal's exported `perform_action("copy")` must accept the selection and copy its complete Unicode contents; a missing Godot method is a failure even when selection rendering succeeds.

Adapted from `shift-drag-selection`. The shared implementation is `selection_copy` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-selection-copy --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-selection-copy --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
