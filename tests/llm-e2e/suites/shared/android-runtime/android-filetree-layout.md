# Android filetree layout

Open a real Mac filetree and viewer through the Android federation, checking connected placement in tiled and floating modes.

Run `mise exec -- uv run tests/android/test_android_runtime.py --serial DEVICE android-filetree-layout`. Use the exported APK and a private Mac owner. Retain the screen recording, checks and logcat. Any unexpected diagnostic, native crash or failed assertion fails the case.
