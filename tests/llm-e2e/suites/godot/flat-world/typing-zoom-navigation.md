# Typing zoom from a navigated view

In both Flat and Flat 2D, configure a 1.15 typing camera zoom.

1. Zoom out to 50%, then type. The view should ease toward 57.5%, retaining
   the chosen view as its baseline. Repeat at 10% and at a zoomed-in view.
2. Stop typing. The camera returns to the saved view without modifying its
   navigation history.
3. Pan until the focused terminal cursor is off-screen, then type. The camera
   should move to reveal it even though the overall view remains zoomed out.
4. The pane title and left edge stay visible whenever they fit with the cursor.
   A cursor too far below the title takes priority, following the normal rule.

Replay: `replays/typing-zoom-navigation.gd`.
