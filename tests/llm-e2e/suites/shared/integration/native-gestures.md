# Pinch and pan intent

For Godot on Windows, run the production-controller replay on a private desktop:

```sh
python tests/platform/windows/windows_private_replay.py \
  --replay tests/llm-e2e/suites/godot/integration/replays/native-gestures.gd \
  --evidence <new-directory>
```

Use a fresh evidence directory and frozen executables. Never inject OS mouse or
keyboard events, take focus, or attach to a personal session.

For zoom-only intent, inspect `native-zoom-only.png` and the recorded projection
requests. The original off-center canvas point must remain under the starting
cursor within two projected pixels, even when the cursor position changes during
the pinch. Magnification must be applied exactly once (1.2 × 1.1 = 1.32).

For simultaneous zoom and pan, inspect `native-zoom-and-pan.png` and its trace.
A wheel translation of (12, −5) must move the remembered zoom point by (36, −15),
using the configured 3× pan speed. The following pinch must stay attached to that
moved point within two projected pixels. Compare the actual world and pane edges
between captures; no unexpected reset or loss of the terminal is acceptable.

After pinch end, a normal wheel event must leave the gesture controller and return
to ordinary terminal scrolling. Record separate PASS/FAIL observations with the
executable hash in `visual-review.json`; a numeric zoom value alone is insufficient.
This replay injects gesture events into the production controller. It does not
prove that the OS delivers physical trackpad events to an inactive window; that
remains a separate device check.
