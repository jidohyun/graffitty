# Status strips during navigation

Use two real tiled panes and the production Main View/pane-fit controls. Run in
both Flat and Flat 2D, sampling the actual tween through its completion frame.

1. Zoom out until status strips appear, and retain their settled placements.
2. Toggle Main View and back. Strips fade out/in while moving with the camera.
   They recover the same placements; hidden Main View must not replace them.
3. Fit a pane and return. Check the same continuity and placement history.
4. Reverse Main View midway. Start from the displayed geometry and opacity.
5. Pan toward a viewport edge so a strip must change sides. Its path follows
   its own pane's outside edges, not a straight line through the pane. Crossing
   a neighboring pane during this brief animation is permitted.
6. During each animation, verify that the placement solver does not rerun and
   remembered positions remain unchanged. Commit only the planned destination.
7. Check every sampled frame for visible overlap with the owner, abrupt position
   or opacity changes, and any correction after the tween finishes. Preserve
   rendered start/middle/end frames of the edge change in each world for review.
8. Interrupt with manual zoom and verify ordinary navigation resumes.

Placement and path geometry live in `graffitty-workspace-core::status_strip`.
The E2E replay covers the Godot integration; Rust tests also check invalid inputs,
all edge-to-edge routes, resizing, and interrupted-path continuity.
