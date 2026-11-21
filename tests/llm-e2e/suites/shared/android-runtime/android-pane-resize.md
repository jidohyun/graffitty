# Android pane resize

Apply three different pane sizes through the client resize command; verify authoritative server grids and unchanged neighbor grids. Then place the neighbor below the floating pane, clear of its touch grips (floating panes keep part of their header reachable, so a narrow phone pulls a far-right neighbor back over the pane), and drag all four edges and four corners with a finger starting 26 screen pixels outside the floating pane, at both reduced and increased zoom. Verify the requested dimensions change, the opposite edge stays anchored, the camera and neighboring grid stay unchanged, and release ends the resize. A second finger must cancel and restore the original rectangle.

Move a floating pane slightly outside Main, navigate to its right edge (a phone cannot show the whole pane), then resize that edge until its center crosses back inside Main. Repeat with tiling disabled and with a tiled neighbor. Only the grabbed edge may change: the pane must keep its floating/stashed membership, opposite edge, and camera framing throughout the drag, release, and server acknowledgment. Neighbors and saved tile proportions must stay unchanged. Only a deliberate move back into Main may rejoin the layout; resizing and cancellation are not drops.

Touch targets are invisible: no handle icons are added. The edge target extends mostly into empty canvas, stays screen-sized through zoom, and must not intercept another pane's content. Mouse targets retain their existing behavior. After returning both panes to Main and enabling tiling, drag a shared divider starting 20 screen pixels off its center; it must resize the tiles without detaching them. On a phone the two tiles can be narrower than their minimum width; the divider must still move, keeping each tile at least a quarter of the shared width.

Adapted from `pane-edge-resize`. The shared implementation is `pane_resize` in `tests/client_scenarios/workspace.gd`; setup may use normal application commands while touch-specific interactions use Godot screen-touch events. A fresh standalone server owns every terminal, chromium and graph in this case.

Run the actual APK:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-pane-resize --serial emulator-5580
```

Run the identical scenario in the thin Mac Godot wrapper:

```sh
mise exec -- uv run tests/android/test_android_runtime.py android-pane-resize --simulated
```

Every assertion must pass, all touch contacts must be released, and the original server PTY must survive. Unexpected engine errors or diagnostic dialogs fail the case. Retain `runtime-state.json`, client/logcat logs and the complete APK screen recording. The Mac wrapper validates shared UI behavior, not Android IME, Keystore, lifecycle or GPU behavior.

Pan to each measured edge before the exterior touch probe so the grip remains
inside the usable workspace on narrow phones at both zoom levels. Keep the
resize, opposite-edge anchoring and no-navigation-change assertions unchanged.
