# Closing a pane inside Main View preserves the camera's Main View

Record the continuous camera motion in both Flat and Flat 2D. Use an isolated
session with tiling enabled and a typing camera preset (idle zoom 1, typing
zoom 1.8, enter duration 0.25 s, idle after 2 s, leave duration 0.6 s).
Do not use Main Area, fit-to-pane, or a gesture to repair the view after closing.

## Close a new top pane in Main View

1. Start with one terminal in Main View. Note its shell PID and the framing.
2. Right-click the vertical split icon to create a pane **above** it. Both panes
   remain within Main View. The new top pane receives focus.
3. Close the new pane using Close Pane. The original terminal receives focus;
   the pointer stays where the user left it.
4. Main View stays selected throughout the close. The camera must not acquire
   a free-navigation pan or zoom, center on the pane body, or drift below the
   tab bar. At rest, its framing matches the view before splitting.
5. The original shell has the same PID and the pane fills the main area again.

## Type after closing and return to the same Main View

1. Type `echo main-view` and Enter in the surviving terminal.
2. Watch the camera zoom toward the active terminal normally, with its header
   reachable. Main View remains the base for the typing animation.
3. Stop typing and watch the complete return to idle. It must return to the
   original Main View without a jump, extra zoom, or residual pan.
4. Repeat the create-above, close, and type cycle; no camera offset accumulates.

## Close while typing with other panes still in Main View

1. Split the original terminal to the right so two terminals share Main View.
   Note both PIDs and the current framing.
2. Create another pane above the original terminal. Type in the top pane until
   the typing camera is visibly zoomed in, then close it before the zoom ends.
3. The nearest surviving terminal receives focus. Closing is not typing input
   and must not restart the typing timer or capture the temporary typing zoom
   as the saved navigation zoom.
4. Main View remains selected even though multiple panes survive. Watch the
   ongoing animation finish and return to the same full Main View.
5. Type in the focused survivor and verify its next zoom and return to idle.
   Both surviving shells keep their PIDs and their original tiled rectangles.

Explicitly panned/zoomed views and surviving stashes retain the separate
[nearest-pane close behavior](close-nearest-pane.md); this case must not force
those views back to Main View. Godot's replay covers application input and
camera telemetry; review the recording for visible animation continuity.
