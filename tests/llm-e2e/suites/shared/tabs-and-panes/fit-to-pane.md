# Fit and restore: keyboard and title double-click

Launch `mise run dev -- --shell=/bin/sh` with an isolated test config. Use Command+Enter on macOS and Ctrl+Shift+Enter on Linux/Windows, without a prefix, while the terminal has keyboard focus. Below, “fit shortcut” means this platform binding. Use actual title-bar double-clicks, including the first press and release, to verify the same toggle through both compact and normal titles. Do not substitute a menu action or direct navigation API for the shortcut. Record continuous motion and capture the starting, intermediate, and settled views. Report PASS, FAIL, or BLOCKED with observations; endpoint screenshots alone cannot prove animation.

## First launch without view history

Start with an isolated config and no restored session, before any pan, zoom, or fit action. The initial single pane already fills Main Area. Press the fit shortcut: smoothly zoom out to center that pane within a box measuring 30% of the usable viewport width and height, preserving its aspect ratio. At least one dimension should reach 30%; neither should exceed it. This changes camera framing, not the pane rectangle or tiling. Double-click its title to return exactly to the initial fitted view. Double-click again to zoom out, then use the shortcut to return. Neither input path may become a no-op just because no prior view exists.

## Animated fit and restore

With one terminal, note its shell PID. Zoom out and pan to a distinctive off-center view. Press the fit shortcut: smoothly fit the pane using the existing title-double-click framing. Press it again after arrival, without panning or zooming: smoothly restore the exact previous framing. Both directions must show intermediate camera positions, with no instant jump or delayed correction.

Make a three-pane layout: one full-height pane on the left and two smaller panes on the right. Label them ALPHA, BETA, and GAMMA and note their PIDs. Focus BETA, then zoom out and pan to an off-center overview. Save this starting frame. Press the fit shortcut: animate to fit BETA with its title and controls visible below the toolbar. Press the fit shortcut again without manual navigation: animate back to the saved frame, matching both pan and zoom. Repeat the pair; the return destination must not drift. Repeat using only title double-clicks, then mix inputs in both directions: shortcut to fit and title to restore, title to fit and shortcut to restore. Both controls must share the same saved view and animation behavior.

## Pan and zoom invalidate restore

Fit BETA, then right-drag to pan. Save this new view. The fit shortcut must now fit BETA again, rather than restore the old overview. A second press without manual navigation must return to this newly saved panned view.

Repeat with pinch or Command/Ctrl-scroll zoom instead of panning. Zooming cancels the old return destination even if the gesture occurs during the fit animation. The next fit/restore pair must use the view reached by the gesture. Ordinary pointer movement without pan or zoom must not cancel the return destination.

## Interrupted animation and session preservation

From an overview, press the fit shortcut and press it again before the fit finishes. It must reverse smoothly from the displayed intermediate frame toward the saved starting view; the abandoned fit animation must not take over later. Pan or zoom during an animation: manual navigation takes control immediately.

Confirm focus stays on BETA, shortcuts do not insert a newline into its shell, and pane rectangles, tiling, tab membership, terminal contents, and shell PIDs remain unchanged. A return view belongs to the pane and tab where the fit started; switching to another pane or tab must never restore an unrelated view. Explicit Main Area or Overview navigation starts a fresh fit/restore pair.

Automated replay: `replays/fit-to-pane.gd`. Run it headless and windowed on macOS, Linux, and Windows to cover the platform binding and fallback/native menus. Verify the chord is received while a shell or CLI application is focused, with no newline or escape sequence delivered to it. On Linux/Windows, do not substitute Super/Windows+Enter or plain Ctrl+Enter. Injected Godot keys must still trigger the action when a native menu exists. The replay checks intermediate and final framing, invalidation, and session preservation. Also assess the native accelerator and visible smoothness with real keyboard input.
