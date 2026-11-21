# android-gestures

Run the direct-touch regression against the connected APK: exact pinch anchors, direct pane and wire dragging, title double-tap, and released contacts.

Measure the real IME through the production keyboard-inset controller, which
receives Android's native editor height. Godot's separate virtual-keyboard API
does not report that editor. Verify accessory layout and typing zoom while the
native keyboard is visible, then dismiss through the same controller.

Run `mise run android:test android-gestures --serial emulator-5580`. Uses a disposable APK and isolated loopback server via ADB reverse. Godot canvas events use the same production handlers as the desktop scenario; android-apk-runtime separately verifies Android-delivered touches. Any unexpected diagnostic, engine error, server focus change or replaced PTY fails. Evidence includes assertions, server checks, logcat, screenshots and Android screen recording.
