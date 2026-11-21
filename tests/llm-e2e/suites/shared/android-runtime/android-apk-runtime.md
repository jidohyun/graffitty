# android-apk-runtime

Runtime: Android emulator or device.

After connecting, enter the workspace through the logo's Touch to start target. A connected server card stays on the connection page; connecting alone does not enter the workspace. Repeat the start action when returning from the connection page or relaunching.

Open the floating menu, then Sessions → Servers to return to connections. Target
the rendered menu rows by their canonical entry IDs, not a fixed number of arrow
keys or translated labels. Diagnostic-window buttons belong to the root window,
and must remain reachable when the panel is docked or floating.

Launch the exported production entry scene in a disposable APK, connected to an isolated desktop fixture. Assert native extension, Java bridge, packaged icons and embedded dialogs load. Deliver actual Android taps to Dismiss, Connections, OK, Fit pane and the Lucide keyboard icon. Assert every target is within the Android SurfaceView, including system-bar offsets. Use real Gboard keys to type, backspace, replace a character and commit to the authoritative terminal; the active client reflows rows above the keyboard, and Back hides the keyboard and restores the original grid. Collect native screen recording, state checkpoints, screenshots and every app process's logcat. Any unexpected dialog or engine error fails.

Related cases cover Unicode/image rendering (`android-remote-state`, `android-images`), portrait menus/dialogs (`android-touch-ui`) and restart/update (`android-lifecycle`).

Run `mise run android:test android-apk-runtime --serial SERIAL`.
