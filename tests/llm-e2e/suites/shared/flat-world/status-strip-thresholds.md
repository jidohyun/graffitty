# Readable pane titles at every zoom

The title font must keep the same readable **on-screen size** while the pane
zooms through manual viewpoint changes. Typing zoom and blur still affect the
title together with the pane. A constant theme font setting is not enough if the camera shrinks the
rendered text. There must be no font-size switch at any zoom threshold.

1. Start at 100% zoom and note the title's rendered glyph height.
2. Zoom to 150%, 100%, 67%, just above and below 50%, 40%, and 27%, then back in.
   The title's rendered glyph height must stay equal to the original, within
   one screen pixel. Check both directions across 50% for sudden changes.
3. The title remains attached **inside the pane's top edge**, with the same
   alignment. It must not float above or drift away from the frame. Long titles
   truncate to fit; they do not shrink their font to fit.
4. The first terminal row stays unobstructed, and the PTY grid does not resize.
5. Only the right-side action icons disappear below 50%. Their invisible buttons
   must not intercept clicks. StatusStrip uses its separate, earlier threshold.
6. Dragging the title, opening its right-click menu, and double-clicking Fit to
   Pane must continue to work at every zoom level.

Any unexpected error dialog is a failure. This contract supersedes the earlier
incorrect expectation that title text should scale down with terminal content.
