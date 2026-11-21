# Pane edges and diagonal resizing

Launch `mise run dev -- --shell=/bin/sh`. Capture screenshots and report PASS, FAIL, or BLOCKED with observations.
Turn off **View → Floating Pane Physics** before arranging panes. These checks compare exact layout and resize positions; collision responses are tested separately in `tests/unit/workspace_physics_test.gd`.


## Expanded first pane and icons

Name the first terminal ALPHA, print its shell PID, and verify tiling is enabled by default. With only one pane, it must fill the entire main area below the workspace controls, with the configured gap on all four edges. It must not retain its former floating size. The pane header must have the blue Chromium icon and a stats icon from Nerd Fonts, with readable tooltips and no Chromium/Monitor text labels.

## Left edge and diagonal tiled corner

Use ALPHA's Split right icon to create BETA. Use ALPHA's Split down icon to create GAMMA. ALPHA and GAMMA are stacked on the left; BETA fills the right side.

Grab BETA's **left border, inside the pane**, away from its top and bottom corners—not just the empty gap. The cursor must indicate horizontal resizing. Drag left: BETA grows wider while both left panes shrink equally. No pane moves out of tiling or overlaps another.

Grab ALPHA's **bottom-right corner**, on the visible diagonal grip. Both an internal column divider and row divider meet there. The cursor must indicate diagonal resizing. Drag down and right: ALPHA grows in both dimensions, BETA gets narrower, and GAMMA gets shorter. All tiles remain within the main area. Begin another diagonal drag, press Escape, then release: the exact previous layout must return.

At an outside edge of the main area with no neighboring tile, resizing must not expand the main area. A corner with only one shared divider can resize only that divider.

## Cancel and floating corner

Turn Tile off. Drag ALPHA's bottom-right grip diagonally from within the visible grip (about ten pixels inside the corner). Its width and height must both grow; neighboring floating windows must keep their positions. Turn Tile back on: the earlier tile proportions return. Verify all three shell PIDs remain unchanged throughout.
