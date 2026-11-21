# android-remote-state

Reuse remote client replay inside the APK: Unicode, ANSI, graph and StatusStrip, shared resize, reconnect, latency and authentication.

Run `mise run android:test android-remote-state --serial emulator-5580`. Uses a disposable APK and isolated loopback server via ADB reverse. Godot canvas events use the same production handlers as the desktop scenario; android-apk-runtime separately verifies Android-delivered touches. Any unexpected diagnostic, engine error, server focus change or replaced PTY fails. Evidence includes assertions, server checks, logcat, screenshots and Android screen recording.
