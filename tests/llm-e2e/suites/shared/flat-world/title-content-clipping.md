# Title masking while zooming

On Mac, run a full-screen terminal application with a bottom status line.
Zoom out until the pane title takes more vertical space and its icons hide.
The title can cover upper rows, but text must not translate downward or shrink.
The bottom status line stays visible at the same location inside the pane.
Zoom back in and verify upper rows reappear without a PTY resize. Repeat in
Flat and Flat 2D. The replay checks fixed texture geometry, unchanged grid,
top masking, and rendered green status text on the final terminal row.
