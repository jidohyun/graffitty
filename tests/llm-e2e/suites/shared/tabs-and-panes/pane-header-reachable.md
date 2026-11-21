# A dragged window's header stays reachable

Regression for windows dragged above the frame, whose headers then hid under
the tab bar and could never be grabbed again.

## Prepare a window

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=2
   ```

2. In the first tab run `printf '\033]0;ALPHA\007'; clear; echo ALPHA`.

## Drag toward every edge

1. Drag the `ALPHA` handle up until the pointer is just below the tab bar,
   then release. Expected: the window's top edge stops at the bottom of the tab
   bar; the header is fully visible.
2. Drag the handle up onto the tab bar, then back down into the content without
   releasing. Expected: over the bar a placeholder tab appears; back in the
   content the window follows the pointer again. Release; no tab was added.
3. Drag the window left until the pointer reaches the left window edge, then
   release. Repeat toward the right and bottom edges.
4. Expected each time: the window may extend past the frame, but at least a
   short stretch of its header handle stays inside the frame.

## Hold at an edge to pan

1. Drag the `ALPHA` handle to each viewport edge and keep holding without
   moving. Expected: after a brief pause the view starts gently and accelerates
   outward at the same zoom. Moving the cursor closer to the edge increases
   speed; pulling inward reduces it. The window keeps following the pointer.
   A window extending offscreen must not cause scrolling while the cursor is
   outside the edge zone.
2. Keep holding. Expected: panning continues beyond the initial Overview
   framing, stopping only at the actual layout placement limits. A stretch of
   the handle remains reachable and its full height stays inside the viewport.
   The Main View outline appears even when panning at the original zoom.
   Release; panning stops and no tab was added.
3. Move away from the edge while still dragging, or press Escape. Expected:
   panning stops immediately. Escape restores the window's original position.

## Verify it can be moved again

1. After each drag, grab the visible part of the handle and drag the window
   back to the middle. It must follow.
2. Resize the application window smaller and larger. Every window header stays
   reachable.
3. Report PASS, FAIL or BLOCKED with a screenshot after each edge drag.
