# Workspace rendering on demand

Run the actual application in a window with an isolated configuration and state directory. Use one terminal, default Flat world settings, and a temporary chromium profile. Report PASS, FAIL, or BLOCKED with evidence. Headless rendering cannot establish pixel updates or GPU-idle behavior. If the native chromium host is unavailable, mark its stage BLOCKED and still complete the terminal and animation stages.

Keep the test window foreground and leave physical keyboard and pointer input idle during automated samples. Concurrent desktop interaction can enter text into the test terminal or pause foreground effects. Do not leave an animated test overlay, live FPS counter, or other diagnostic UI running during idle samples: it would itself request redraws. Measure completed render frames with an in-memory counter, then print the result after each sample. Record continuous motion during animation checks separately. CPU percentage is supporting evidence, not a portable pass/fail threshold or a measurement of watts.

## Idle and terminal wake-up

Disable cursor blinking and wait for startup and typing effects to settle. With no moving pointer, chromium, animation, or terminal output, observe a quiet interval of at least one second. There must be no sustained frame loop; incidental OS invalidations are acceptable, but a continuous 30/60 FPS stream is a failure. The terminal session must remain alive.

Arrange delayed terminal output, then leave the workspace idle. The new text must appear without moving the pointer, pressing another key, or resizing the window. Verify both terminal text and the final composited window pixels change. Confirm it returns to idle after the output and effects settle. Enable cursor blinking: the cursor must visibly blink, waking only the necessary frames. Disable blinking again and verify idle rendering resumes.

## Input, navigation, and effects

Type into the focused terminal. Echo and typing effects must become visible promptly. Open and dismiss a menu; hover a pane button. These UI changes must appear even after a long idle interval. Pan and zoom, then press Command+Enter to fit the pane and again to restore the previous view. Both animations must show intermediate frames, end at their intended framing, and stop producing frames after settling.

Repeat with typing sparks/ripples enabled. Observe the effect while active and after its final particle has disappeared. A shader clock, an empty particle pool, or repeated unchanged style updates must not keep rendering alive. While content is active, rendering must be capped at 60 FPS. Losing and regaining window focus and switching worlds must not remove the cap; the existing 30 FPS background limit may remain.

Allow the configured adaptive camera ease to settle before the idle sample:
the typing idle delay, leave duration, and three times the longer adaptive
zoom duration. The subsequent one-second idle interval still allows at most
two incidental redraws. The projection must finish exactly rather than keep
rewriting depth values with an imperceptible interpolation tail.

## Chromium GPU frames

Open a local or data-URL page with a solid red body in an embedded chromium pane using a temporary profile. Wait until it is visible and settled. Without terminal input or pointer motion, change the page to solid blue using a timer or chromium automation. Confirm the chromium's received GPU frame count advances and the final application window visibly changes from red to blue. A received texture with frozen final window pixels is a failure.

Start a page animation that changes its color or counter several times per second. Observe several distinct page frames in the embedded pane while leaving terminal input idle. Stop the animation, close the chromium pane, wait for layout/effects to settle, and confirm the terminal workspace returns to idle rendering. Chromium closure must not leave an always-redrawing compositor or break the remaining terminal.

Automated replay: `replays/render-on-demand.gd`. It reuses `tests/workspace_render_updates_smoke.gd` for deterministic idle, terminal, cursor, and animation checks, and adds real Chromium GPU-frame and final-pixel checks. Its screenshot helper makes the dashboard run it windowed. The lower-level smoke test remains runnable without the chromium host.
