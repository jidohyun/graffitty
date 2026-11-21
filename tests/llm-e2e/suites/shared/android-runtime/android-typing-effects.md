# Android typing effects

Exercise real remote key input, animated typing state and cancellation across pane focus changes.

Run `mise exec -- uv run tests/android/test_android_runtime.py --serial DEVICE android-typing-effects`. Use the exported APK and a private Mac owner. Retain the screen recording, checks and logcat. Any unexpected diagnostic, native crash or failed assertion fails the case.
