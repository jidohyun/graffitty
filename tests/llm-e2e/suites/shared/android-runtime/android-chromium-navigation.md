# Android chromium navigation

Create a real server chromium and receive frames. Aim the centered cursor at its unobstructed address field, double tap, edit with Cmd/Ctrl+A, and press Enter to navigate. Focus must survive the Android keyboard shrinking the workspace. Also verify Unicode DOM input, Back/Forward, and closing only the chromium. Open a second tab and drag the first tab past it with a touch: within three seconds the pane's tab strip must show the order the server confirms, rather than the previous order until the strip's timeout.

Adapted from `headless remote chromium`. The shared implementation is `chromium_navigation` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Fit the browser in the available workspace before checking hardware video negotiation. Tiny overview panes intentionally pause video and show a PNG preview; that preview alone cannot establish decoder failure or a hardware-streaming pass.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-chromium-navigation --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-chromium-navigation --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.
