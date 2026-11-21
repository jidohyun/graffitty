# Tiling drag preview

Launch `mise run dev -- --shell=/bin/sh`. Enable Tile and create three windows in one tab. Record continuously through the drags, with screenshots while the mouse is held.

## Preview a split and cancel

Drag the third pane over the bottom edge of the first pane, holding the button. A blue proposed destination and outlines of the other resulting tiles must appear before release. Moving toward another edge must change the proposal. Existing windows and PTY sizes must not reflow during hover. Escape must clear the preview and restore the original placement and split tree.

## Commit the preview

Repeat the drag and release. The final positions must match the preview exactly. The overlay must disappear. In Overview, moving outside the main border must clear tile highlights while retaining the proposed stash transaction. Dropping stashes the pane and refills the remaining tiles according to that proposal; cancellation keeps it tiled.

## Preview a merge from another tab

Create another tab, drag its pane onto the original tab, wait for hover activation, and move into the tiled area. The destination must preview the incoming split and all affected tiles while the original tab still owns the pane. Releasing commits that same proposal. Repeat with a whole tab containing two windows; both must appear in the proposal and final layout. Include attached chromium panes in the proposal if present; none may disappear. Report PASS, FAIL, or BLOCKED with the before-release and after-release evidence.
