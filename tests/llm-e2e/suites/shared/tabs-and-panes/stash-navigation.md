# Inspect stashed panes up close

Launch `mise run dev -- --shell=/bin/sh`. Capture screenshots and report PASS, FAIL, or BLOCKED with observations.

## Stash and inspect

Create two panes, ALPHA and BETA, in one tiled tab. Note both shell PIDs. Pinch out to an overview. Original pane titles must keep a constant readable on-screen font size inside their pane frames, without any threshold-based size change, with separate multiline PID and CPU/RAM icon panels above them; tiny action icons must disappear instead of becoming crowded or remaining invisible clickable targets. The terminal grid must not reflow. Drag BETA by the original pane title (including the lower half of its label) outside the right edge of the main area. Leave BETA stashed. Put the pointer over BETA and pinch outward with two fingers to zoom in beyond the former Overview limit. The point under the pointer must stay anchored, and the camera must not snap back to the main area. The main-area border and pane positions must not change.

## Navigate and type

Hold the right mouse button and drag horizontally and vertically to center the stashed pane. Inspect it at normal readable size or larger. Verify rendered pixels, not only layout coordinates. Click BETA and type a marker: it must reach the same shell while the camera remains at the stash. Unmodified two-finger scrolling over BETA must not pan the workspace. Pinch in and out while inspecting it; the view stays anchored near the pointer. Neither navigation gesture moves, resizes, unstashes, or retiles panes.

## Worlds and reset

Choose View → Fit to Main Area. It must reset pan and zoom, keeping BETA stashed. From Main, right-drag directly back to BETA without first using Overview. Repeat close inspection in Bistro (night). PIDs, tab membership, and stashed rectangles must survive. Overview remains a fit-all command, and Main area always provides a way home. Finally, double-click BETA’s compact Overview title: its pane must open at readable scale, restoring its full header controls without moving or unstashing it.
