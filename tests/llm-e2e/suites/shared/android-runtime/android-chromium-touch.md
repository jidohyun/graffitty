# Chromium touch

Run `uv run tests/android/test_android_runtime.py android-chromium-touch --serial SERIAL` for the physical Android client, or use `--simulated` for the Mac Godot client. Build the current Android extension first with `uv run --no-project tools/build_android.py`.

The shared workspace scenario fits a real Chromium pane and loads a tall page with a click counter. Touch contacts go through the production `MobilePointer` recognizer:

- One finger drags the page upward and holds still before lifting, so no fling adds distance. The page must scroll as far as the finger moved, measured in page pixels from the pane's displayed size, within 25%.
- The drag must neither click nor select text. Chromium pages always scroll with one finger; the terminal's scroll-finger preference does not apply to them.
- A quick tap at the pane's center must click the page exactly once, near the center of its viewport.

Retain runtime state and logs. `CHROMIUM_TOUCH_DRAG` records the scroll position, the expected distance and the displayed rectangle; `CHROMIUM_TOUCH_TAP` records the click coordinates.
