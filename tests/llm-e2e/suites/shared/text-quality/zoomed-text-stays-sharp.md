# Zoomed text stays sharp

Zooming used to enlarge a texture rendered for the resting view, so text got
softer the closer the camera came.

## Print text and look at rest

1. Launch from the repository root:

   ```sh
   mise run dev -- --shell=/bin/sh
   ```

   Configure the fixed typing zoom first (adaptive framing is the default):
   `[effects.camera]` with `zoom_mode = "typing"` and `zoom = 1.15`.

2. Run `echo The quick brown fox jumps over 0123456789` and wait until the
   camera has settled back to rest.
3. Take a screenshot of the printed line. This is the reference: note how many
   screen pixels a glyph edge takes to go from background to text.

## Zoom in by pinching

1. Over the printed line, pinch outward until the text is about three times
   larger, and wait a second.
2. Take a screenshot of the same line.
3. Expected: the glyph edges are as crisp as in the reference. Enlarged but
   blurry edges, or visible square pixels, fail.
4. Pinch further, to about five times, and repeat. Expected: still crisp.
5. Type a few characters so the typing zoom engages, and check the text around
   the cursor the same way.

## Compare with Bistro

1. Choose **View > World > Bistro** (BLOCKED if missing).
2. Repeat the pinch and typing checks on a Bistro wall. Depth of field may soften
   text away from the cursor; the text at the cursor must be crisp.
3. Report PASS, FAIL or BLOCKED with the reference and zoomed screenshots side
   by side at the same on-screen size.
