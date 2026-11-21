# Android scene retention

Freeze a remote scene in copy mode, apply held output on exit, and restore an inactive tab without producing new output.

Run `mise exec -- uv run tests/android/test_android_runtime.py --serial DEVICE android-scene-retention`. Use the exported APK and a private Mac owner. Retain the screen recording, checks and logcat. Any unexpected diagnostic, native crash or failed assertion fails the case.
