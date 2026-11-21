# System Ui

Runtime: Android. Emulator or physical device.

Report PASS, FAIL, or BLOCKED with evidence. This procedure needs recorded LLM/manual execution. The automated APK cases cover shared client logic, English Gboard input and basic lifecycle, but do not establish this additional coverage as passing.

1. Use an isolated connection, with terminal output and a deliberately displayed Graffitty messages panel.
2. Copy terminal/message text through the client's available copy action, then paste into another Android app. Copy English, Korean, emoji, and multiline text from that app and paste into the focused terminal. Check exact server text.
3. Exercise Android Back with a client dialog and with the system keyboard open; verify only the intended layer closes.
4. Exercise any supported external-link or log-opening action through the Android intent resolver. A desktop shell-open call is not evidence for this boundary.
5. Exercise Android split-screen and lock/unlock, including with the keyboard visible. Verify controls avoid actual status/navigation bars, display cutouts, and keyboard insets in portrait and landscape.
6. On a test environment configured for the supported network path, interrupt and restore Android connectivity while connected. Verify the reconnect path and server session continuity. If testing Tailscale, exercise the actual Android VPN app; a local loopback server only validates the transport.

Use UI Automator/ADB for Android system UI; use Godot state assertions and injected touch for the canvas. Do not assume Godot's drawn buttons are Android accessibility widgets. Do not add notification/permission test requirements for features the Android client does not implement.
