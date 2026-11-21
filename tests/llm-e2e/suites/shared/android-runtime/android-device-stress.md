# Device Stress

Runtime: Android. Physical device required.

Report PASS, FAIL, or BLOCKED with evidence. This procedure needs recorded LLM/manual execution. The automated APK cases cover shared client logic, English Gboard input and basic lifecycle, but do not establish this additional coverage as passing.

Requires a physical phone; keep this within the Android-runtime suite but mark emulator-only execution BLOCKED for this case.

1. Record model, Android version, GPU/renderer, screen density, and APK identity. Connect to an isolated server containing several panes, graphs, and terminal images.
2. Repeatedly pinch, pan, fit panes, switch tabs, and show/hide the keyboard. Measure application/graphics memory and capture crash/exit reasons. Verify the mobile render-target cap is retained.
3. Background/foreground and lock/unlock repeatedly. On foldables, fold/unfold with a connection and keyboard active.
4. Verify actual multitouch cancellation, OEM keyboard behavior, small-text appearance, and controls near gesture-navigation edges.
5. Look for GPU fence failures, low-memory kills, stale surfaces, or stuck input. Preserve logs and screenshots with the result.

An emulator can detect some rendering/lifecycle failures, but cannot certify the phone's GPU driver, memory pressure, touch hardware, thermal behavior, or OEM integration.
