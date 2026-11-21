# Main area and nested tiling

Launch `mise run dev -- --shell=/bin/sh`. Capture screenshots at each stage. Report PASS, FAIL, or BLOCKED with observations; model state alone cannot establish visual correctness.
Turn off **View → Floating Pane Physics** before arranging panes. These checks compare exact layout and resize positions; collision responses are tested separately in `tests/unit/workspace_physics_test.gd`.


## Tile and split

Name the first terminal ALPHA and print its shell PID. Verify tiling is enabled by default and its menu toggle is absent. In ALPHA's header, click the **Split right** icon (a frame divided into columns, right half highlighted) to add BETA. They must share one tab and split the main area horizontally without overlap. In BETA's header, click the **Split down** icon (a frame divided into rows, bottom half highlighted) to add GAMMA below it in one click. ALPHA must keep the full left side; BETA and GAMMA must share the right side vertically. This is a nested split tree, not a three-cell grid. Each shell must accept input independently.

## Resize tiled panes

Drag the gap between ALPHA and the right-hand branch to widen ALPHA. BETA and GAMMA must shrink together without overlapping or leaving the main area. Drag the gap between BETA and GAMMA downward: BETA grows taller, GAMMA shrinks, and ALPHA stays unchanged. The cursor should indicate the resize direction. Panes and terminal grids must follow the drag live; no new shell is created. Drag far beyond the edge and confirm minimum pane sizes prevent collapse. Press Escape before releasing: the exact pre-drag proportions must return. Stashed windows must not resize or move with a tiled divider.

## Resize and toggle

Resize Graffitty from wide to tall and back. The main area must track the usable window width and height; tiled panes must refit without overlap and preserve the chosen column and row proportions. Pinch out: a border must show the main area with its new aspect ratio, with free surrounding space. Choose **View → Fit to Main Area**, then disable tiling through the replay helper for internal floating-layout coverage. Windows must remain at their visible positions and become freely movable. Turn it back on: they must tile again.

## Preserve sessions

Confirm three windows remain in the same tab and all original PIDs and printed markers survive layout changes. Switch tabs and return: tiling, the nested split direction, and resized proportions must belong to the tab. Run `gft tiling balance-sizes`: both the outer columns and nested rows must return to equal sizes. Small windows may clip pane chrome, but must never enlarge the main area or overlap adjacent tiles.
