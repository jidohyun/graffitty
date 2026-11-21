# Tiling CLI

Launch `mise run dev -- --shell=/bin/sh`. Run commands from a terminal inside the app, using `"$GRAFFITTY_BIN" tiling`. Capture the commands and resulting layout.
Turn off **View → Floating Pane Physics** before arranging panes. These checks compare exact layout and resize positions; collision responses are tested separately in `tests/unit/workspace_physics_test.gd`.


## Layout and split

Run `layout h_tiles`, then `new-window` twice. Three equally sized horizontal tiles must appear in the same tab with independent live shells. Run `split vertical` before opening another window: it must split the focused pane vertically. `status` must report the tab, focused pane, mode, split tree, and stashed panes.

## Focus, join and move

Run `focus up` from the new bottom tile. Focus must reach its top neighbor. Run `join-with left`: the focused window and its left neighbor must share a vertical container, following AeroSpace's opposite-axis grouping. The focused pane joins below that neighbor. Use `move up` and verify it moves before its neighbor while keeping keyboard focus. Other tabs and shell processes must remain unchanged.

Run `layout floating tiling` twice. The first call switches to floating without moving panes; the second returns to tiling. `layout horizontal vertical` must cycle the root orientation. Unsupported layouts such as `accordion` must fail without changing the tree.

## View and scope

Run `view overview`, then `view main`. These must use the same view controls as the toolbar. `balance-sizes` must leave equal sibling sizes. Commands from an inactive tab must fail with `inactive_tab`; they must not select that tab. In a basic world that does not opt into `TerminalSpace`, commands must fail with `unsupported_layout` and must not inject workspace controls.

Report PASS, FAIL, or BLOCKED, with commands, before/after layouts and shell PID continuity. The authoring opt-in boundary is also exercised by `tests/terminal_space_smoke.gd`.
