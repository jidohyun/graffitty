# Main view magnet

Pinch out, then pinch back close to the Main scale at the main-view center.
The view snaps to the exact Main scale and center while fingers are moving,
and saves that framing. Continue pinching with small increments: movement
accumulates through the magnet until the view pulls free. Stopping outside
the magnet causes no delayed correction.

Repeat with simultaneous zoom and pan. When both position and scale approach
Main, the view snaps; continued pan-only updates during the pinch pull it free.
Near Main scale but far from its center, preserve the sheet point under the
moving gesture anchor without snapping. Ordinary panning back near Main must
still snap as well. Repeat in Flat and Flat 2D.

Explicit Main restores the exact center and scale, including the saved view;
explicit Overview clears the magnet. Pane rectangles and shell PIDs survive
every step.
