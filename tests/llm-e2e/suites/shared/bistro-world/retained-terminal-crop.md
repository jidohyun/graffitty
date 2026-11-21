# Retained layout and world switching

1. Launch a production frontend on an isolated owner. Open Bistro, create eleven
   terminal tabs, and select the eleventh. Retain the owner's pane geometry.
2. Switch to Flat and back to Bistro. Exercise a client canvas smaller than the
   owner layout (the Godot regression uses a 1264×750 pane and an 800×500 canvas).
3. At normal zoom, fill the terminal with numbered rows and long lines. Place
   explicit markers near the right and bottom cell-grid edges. Record the whole
   sequence and save the final rendered frame plus pane/crop geometry.
4. Require the visible pane to render completely, with readable right/bottom
   markers. Neither text, title nor background may be cut off at a rectangle
   matching the smaller client canvas. Test pan/zoom and interrupted tab flights,
   then return to normal zoom and verify the settled view again.
5. Fill multiple tabs with text through the bottom rows. Capture consecutive
   frames from the final assembled transition pieces through the first live
   terminal frames. Require continuous text, title and background visibility:
   no one-frame disappearance, old crop, or blank texture at the handoff. Repeat
   with a second tab switch interrupting arrival and with a world switch.
6. Compare terminal attachment against the authored Bistro wall landmarks.
   Resize the client while retaining owner geometry:
   terminal corners must keep their world-space positions, not slide or enlarge
   on the wall. Camera fitting alone cannot establish correct attachment. At the default main
   view, also require the authored camera eye to remain unchanged across client
   sizes; inspect nearby landmarks (such as the terrace furniture) for changed viewpoint.
7. Require unchanged terminal identity and grid unless an explicit pane resize
   was performed. Fixing clipping by enlarging fonts, shrinking the owner pane,
   or dropping content does not pass. Unexpected errors fail the case.

The Python Godot adapter uses a real server, terminal and background GPU rendering
and records both final-window and terminal-texture PNGs. It checks that the fitted
pane lies inside the render crop; source texture correctness alone is insufficient.
Review the rendered evidence independently for every required frontend. Missing
adapters or recording coverage remain BLOCKED, not PASS.
