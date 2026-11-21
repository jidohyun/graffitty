# Flat-world camera zoom survives a tab switch

## Prepare config and tabs

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=2 \
     --config=tests/llm-e2e/suites/godot/flat-world/camera-zoom-tab-switch.conf
   ```

2. Confirm two terminal tabs are open and the camera is idle.

## Type and switch while zoomed

1. Type in the first tab until the camera zooms in.
2. While zoomed in, click the second tab.
3. Stop typing and watch the animation finish.

## Verify animation continuity

1. Confirm the second tab is active.
2. Confirm the camera moves smoothly while glyphs leave and the backing recedes.
3. Confirm the camera eases to the destination while it builds, without jump-cutting or freezing during that movement.
4. Repeat with dense text in both tabs, typing zoom around 1.8, camera tilt of
   12 degrees, depth-of-field blur, and the Mild preset's purple defocus tint.
   Print repeated alphabet/number rows so blur and brightness are measurable.
5. For Godot, run the Push/Pull tab transition in both directions (to a later
   and to an earlier tab). The fixture selects the fixed typing zoom with
   `zoom_mode = "typing"`; adaptive framing is the default.
   Other frontends must exercise their supported Scatter
   transitions. Review consecutive rendered
   frames at departure and arrival. Switching from live text to captured pieces
   must preserve blur, color, brightness, and antialiased glyph coverage. The
   retained full-pane capture can resample a cropped live texture: the dense
   fixture permits under 2% mean absolute RGB error, while separately requiring
   mean-color distance below 0.005 and edge-energy change below 12%.
   The following one or two frames must not suddenly sharpen or brighten the text.
   Blur may ease away during flight; it must not jump when the camera's typing
   zoom resets. Replacing assembled pieces with live text must also match.
6. Retain all rendered flight frames and lens telemetry. The Godot replay prints
   `ZOOM_APPEARANCE_EVIDENCE` directories containing a 60 Hz frame sequence and
   `lens.json`. Coordinate-only or headless results cannot certify appearance.
