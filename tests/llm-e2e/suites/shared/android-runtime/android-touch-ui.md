# android-touch-ui

Reuse Android UI replay inside the APK: tabs, messages, embedded menus, toolbar, portrait layout and pane fit.

Run `mise run android:test android-touch-ui --serial emulator-5580`. Uses a disposable APK and isolated loopback server via ADB reverse. Godot canvas events use the same production handlers as the desktop scenario; android-apk-runtime separately verifies Android-delivered touches. Any unexpected diagnostic, engine error, server focus change or replaced PTY fails. Evidence includes assertions, server checks, logcat, screenshots and Android screen recording.
