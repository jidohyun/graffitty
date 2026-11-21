# One camera for the world and every window

## Prepare two windows in one tab

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=2
   ```

   Configure the fixed typing zoom first (adaptive framing is the default):
   `[effects.camera]` with `zoom_mode = "typing"` and `zoom = 1.15`.

2. In the first tab run `printf '\033]0;ALPHA\007'; clear; echo ALPHA`, in the
   second the same with `BRAVO`.
3. Merge BRAVO into ALPHA: drag BRAVO's tab onto the middle of ALPHA's tab,
   hold until ALPHA's content shows, move down into it and release. If that
   fails, report BLOCKED and refer to `tabs-and-panes/tab-hover-merge`.
4. Drag the windows by their headers so both are fully visible side by side.
   Take a screenshot at rest.

## Type and watch the camera

1. Start a screen recording. Click inside BRAVO and type steadily for three
   seconds.
2. Expected: the whole workspace, both windows and the background, zooms
   toward BRAVO's cursor as one scene. ALPHA moves and scales with it; it does
   not stay fixed while only BRAVO's content zooms.
3. Expected: the view leans gently toward the cursor's side, without
   wide-angle stretching. ALPHA and the far side soften and darken slightly;
   text around the cursor stays sharp. The tab bar never moves.

## Interact while zoomed

1. Type a few more characters in BRAVO, then immediately click inside the
   visible part of ALPHA.
2. Expected: ALPHA takes the keyboard (typed text appears in ALPHA) and the
   camera glides to ALPHA's cursor, without cutting to another view.
   Keep docked panels visible: cursor containment at their boundaries must
   follow the eased cursor during the focus change instead of snapping the camera.
3. Pinch on the trackpad over empty background. Expected: the whole scene
   zooms, not a single window.

## Verify rest

1. Stop typing and wait three seconds.
2. Expected: the camera eases back, and both windows return exactly to their
   arranged places, sharp and evenly lit. Compare with the rest screenshot.
3. Report PASS, FAIL or BLOCKED with the recording and both screenshots.
