# Chromium crash recovery

Run `uv run tests/android/test_android_runtime.py android-chromium-crash-recovery --serial SERIAL` for the physical Android client, or use `--simulated` for the Mac Godot client. Build the current Android extension first with `uv run --no-project tools/build_android.py`.

The shared workspace scenario opens a Chromium pane and waits for its pixels. The runner then kills that Chromium's host process on the server computer (a desktop client stops it directly), as a fatal browser abort would end it. The client must post exactly one error notification and replace the frozen page with a message offering Restart. The scenario taps Restart; the same pane must relaunch with a new host process, stream new frames, hide the message and, when the client advertises hardware codecs, keep hardware video.

The runner then kills the relaunched host's page renderers, which leaves the browser running. The client must post exactly one error notification and show a crashed-page message offering Reload, not Restart. The scenario taps Reload; the page must get a new renderer, stream new frames and hide the message.

Finally the page is put in an endless script loop. The client must show "This page is not responding" with Reload; tapping it must load the page again and resume the stream. Processes are only ever SIGKILLed and the stuck page is not crashed, so the run leaves no crash report for macOS to show as a dialog. The original terminal must survive.

Fit the affected pane before each recovery tap and choose an exposed part of the button when floating controls overlap it. Floating controls retain their normal placement and hit priority.

Repeat in a narrow phone pane: the failure heading wraps within the pane and recovery/close actions flow into additional rows instead of extending beyond its clipped right edge.
