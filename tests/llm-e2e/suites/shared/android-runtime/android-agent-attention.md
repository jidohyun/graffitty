# Android agent list and attention sound

Use the existing Android runtime harness and a disposable server/terminal.
Register a fixture Pi agent through the real CLI hook, then send busy/waiting/idle
transitions through the real server RPC. Also run an ordinary shell process that
emits OSC 7501 `app=pi` working/blocked reports without any provider hook. Verify it
appears in Agents and alerts while its graph provider remains `shell`. Do not
modify a user's running agent.

Verify the production controller sees the server's agent. Open `Agents` through
the real command line and assert it fits the keyboard-safe viewport. The window
opens in its default sidebar dock. Set it floating before the window gestures;
the floating window must be non-modal, touch-draggable and touch-resizable. Selecting its rendered mod row focuses
the agent pane without closing the list. See UI-07 in `tests/e2e/controls.md` for
the real IME, rotation and repeated-keyboard acceptance matrix. Waiting must trigger one native
sound even with Godot's Dummy driver; repeated refreshes must not repeat it.
Start the disposable app without RECORD_AUDIO permission. Assert that Godot's
configured driver is still Dummy and microphone permission remains ungranted both
before and after all alerts and the controller's internal test playback (there is
no Test sound button in the dialog). Verify the resize area has no triangle label. Playback must not require a
microphone permission prompt. A separate ADB microphone recorder belongs to the
shell, not Graffitty, and does not grant microphone access to the app.
Client mute must prevent subsequent playback. Native output must close after the
sound, with no idle stream left open. Record the actual Android audio output (or
human audibility), not merely a playback callback. A simulated run is not a
physical-device pass. Keep recordings, connection details and logs outside Git.
