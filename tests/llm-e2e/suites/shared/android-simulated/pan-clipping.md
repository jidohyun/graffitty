# Off-screen terminal panning

Show numbered columns or coloured cell markers in a terminal. Pan the pane
partly beyond each screen edge without changing zoom. Visible text must retain
its cell width, height and relative position; off-screen content is clipped,
never squeezed into the visible part. Repeat while pinching, stop, and pan back.
The automated scenario samples rendered colours at projected cell positions
through a continuous pan and checks unchanged zoom and terminal dimensions.
