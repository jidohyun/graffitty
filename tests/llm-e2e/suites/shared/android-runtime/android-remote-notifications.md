# Android remote notifications

Deliver OSC 9 and OSC 99 from a Mac PTY to Android without desktop-helper errors and verify continued input.

Run `mise exec -- uv run tests/android/test_android_runtime.py --serial DEVICE android-remote-notifications`. Use the exported APK and a private Mac owner. Retain the screen recording, checks and logcat. Any unexpected diagnostic, native crash or failed assertion fails the case.
