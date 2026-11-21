# Android entry smoke

Run `mise run android:build`, then `mise exec -- python3 tests/android/test_android_runtime.py android-entry-smoke --serial SERIAL`.

The runner exports a disposable `com.graffitty.runtime_test` APK around the real remote manager scene. It installs only that package and removes it afterward. It does not alter the user's installed client.

1. Verify Android runtime, native Terminal extension, Java bridge, packaged keyboard icon, and embedded production first-run connection form.
2. Send Home, then reopen the activity. Require actual pause and resume callbacks, and continued state updates without engine errors.
3. Force-stop and relaunch. Require a new process launch count persisted in app-private storage.
4. Update the APK without clearing its data and relaunch. Require the next persisted launch count.
5. Retain device/API/ABI identity, screenshot, state snapshots, export log and logcat. Missing runtime is BLOCKED, not PASS.

This automated smoke is deliberately narrower than `android-apk-runtime` and `android-lifecycle`: it does not prove remote session restoration, actual IME input, activity recreation, rotation, lock/unlock, or phone memory/GPU stability. Those procedures remain required.
