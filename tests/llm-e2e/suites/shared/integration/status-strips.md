# Overview status strips

For Godot on Windows, run `python tests/platform/windows/windows_feature_acceptance.py --suite
status-strips --evidence <new-directory>`. Use disposable server processes and
capture the whole window, since a raw world texture omits screen overlays.
Keep normal human desktop input untouched.

## Read real per-pane status

1. Create two panes with different live shell PIDs. Wait for the shared server's
   actual resource samples; do not inject expected metrics into the UI.
2. Register an adapter in one pane with an advertised input/output and set its
   agent state. Keep the other pane a plain shell.
3. Zoom out until each projected 30px header is shorter than 24 logical pixels,
   then wait for the camera flight and arrival fade to settle.
4. Capture the UI. Read each pane's title, CPU and RAM from its visible strip.
   CPU and RAM must appear side by side on one row, with the pane title above
   and the optional agent badge below, on desktop and Android.
   Compare the values with that pane's resource sample, allowing display
   rounding and normal new samples. Only the adapter pane has an agent badge.
   Distinct metadata alone does not prove that the text is visibly rendered.

## Pan and avoid ports

1. Pan the overview and slightly change zoom. The strips move with their own
   projected panes while retaining readable text size.
2. Inspect all strip rectangles against projected terminal/chromium content,
   other strips and advertised ports. Content overlap is always a failure.
   Port overlap is permitted only if every otherwise valid perimeter position
   requires it; it must not be the first choice when a clear position exists.
3. Select text or drag a connection near a strip. The strip itself must not
   capture pointer input or change the focused shell.
4. Capture at least two camera positions and retain projected geometry and
   server resource samples beside those images.

## Check hidden and unavailable states

1. Fit a pane: the overview strip disappears when the projected header reaches
   normal size. Move a pane fully offscreen: it has no floating orphan strip.
2. Switch tabs and return. Only panes in the active destination show strips;
   outgoing/arriving surfaces do not leave a stale overlay during the flight.
3. If a sample is missing, warming up, stale or offline, require an explicit
   unavailable label/em dash. Unknown usage must never be shown as measured
   zero. Use a real disconnected test host for the offline state when available.
4. Report unavailable runtime checks as BLOCKED rather than passed.
