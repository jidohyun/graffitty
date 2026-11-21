# Direct Android touch

Single taps activate the control under the finger. Drag pane titles and node output sockets directly to their destinations. Double-tap a title to fit its pane. Two-finger pinch keeps the existing moving-center behavior and cancels any one-finger drag. There is no center cursor.

Terminal content scrolls with one finger by default; double-tap-and-drag selects.
Use View → Terminal Touch Scrolling to switch between One Finger and Three Fingers.
The latter permits ordinary one-finger selection. In both modes, adding a second
finger cancels any pending selection and starts pinch navigation without copying.

At a pane's client-local fit scale, its header actions must be visible and readable. They hide below half that fit scale, independently of the desktop/server view. Typing and opening the IME must keep the terminal cursor visible without rewriting saved navigation each animation frame. Insert/command cursor shapes must survive streamed output and reconnect snapshots.

Run `uv run tests/android/test_android_runtime.py android-direct-touch --serial SERIAL`. Retain the APK video, state checks, and logcat. The simulated wrapper covers direct touch routing but not the native IME.
