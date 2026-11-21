# Native Android input

Run `mise run android:test android-native-input --serial emulator-5580` after building.

This automated case uses the same disposable APK as entry-smoke. ADB taps the
production connection form using the actual Android SurfaceView bounds. UI
Automator locates keys in the installed IME; ADB taps those keys. The app must
receive `abc`. Android Back must hide the keyboard while retaining the form.
Unexpected diagnostics fail. Retain keyboard screenshots, UI hierarchy and state.

This tests real IME event delivery, not `adb input text` or injected Godot key
signals. It does not replace the full `android-ime` Korean composition/terminal
routing procedure. The VM needs a configured English keyboard exposing accessible
letter keys (the installed Google APIs image provides Gboard).
