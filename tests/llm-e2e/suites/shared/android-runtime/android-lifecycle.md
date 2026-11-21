# android-lifecycle

Runtime: Android emulator or device.

Connect the production manager to an isolated desktop server. Start delayed terminal output and a held double-tap selection drag, press Android Home, wait while backgrounded, and reopen the activity. Assert pause/resume callbacks, released touches/buttons and background output arriving. Seed the connection only on the first launch; later launches must read the actual persisted production configuration. Force-stop/relaunch, then install an APK update without clearing data and relaunch. Both must restore the saved connection and server terminal text, with no held touches/buttons or duplicate panes. The fixture verifies original server PTYs and desktop tab/focus throughout. Capture all process logs and an Android screen recording.

This tests actual Android backgrounding and process restart, not low-memory eviction. Portrait surface recreation is covered by android-touch-ui; split-screen and lock/unlock remain in the manual system-UI/device procedures.

Before backgrounding, select a tab other than the first, focus a secondary pane,
and pan/zoom away from Main View. After returning through the server chooser,
disconnecting/reconnecting, and force-stop/relaunch after Home, verify that the
same tab, pane, and browsing view return. Repeat with Main View selected and
verify it remains fitted. Closing the remembered tab or pane from the desktop
while Android is away must fall back to an available target.

Also background the app while its network/VPN route is interrupted, restore the
route, and return. Keep a desktop client attached to confirm the server and PTY
remain healthy. Android must detect a silently lost connection, show its offline
status, and retry automatically. Once connected, reopen the workspace/keyboard
and verify new typing updates the terminal exactly once without manually
disconnecting. Input attempted during the outage must not be replayed. A healthy
connection must survive returning with an unread heartbeat response.

`python3 tests/godot/test_remote_resume.py` covers the silent connection loss with a
real owner, two native Godot clients, and a relay that drops traffic without
closing TCP. It verifies recovery, PTY continuity, and production-manager view
restoration across reconnects and a fresh manager loading saved state; it does not replace the
Android lifecycle and native keyboard checks above.

Run `mise run android:test android-lifecycle --serial SERIAL`.

On Flat 2D startup, restore the remembered pane before activating a terminal; selecting the first pane in tree order would overwrite the saved focus before the workspace opens. Cover a remembered pane with stable ID %1 appearing second in tree order.

Use a short output marker that fits narrow phone terminal columns, constructed from separate printf arguments so echoed command text cannot satisfy the background-output assertion.
