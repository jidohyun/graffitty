# Pane-local font size and recent preference

Use an isolated user state directory and a disposable workspace. Start with no
recent font preference, and create two terminal panes A and B before changing
any font. Print the same multiline sample and `echo $$` in each. Record their
initial font size, cell dimensions, shell PID, and terminal grid dimensions.

## Independent existing panes

Focus A. Press Command+= twice (use the configured platform shortcut). Only A's
terminal text and cell size should grow. B's font, grid, and shell must stay unchanged.
Focus B, then A again: neither should adopt the other's size. Decrease B once:
only B should shrink, while A retains its larger font. Check in tiled and floating
layouts and after switching tabs. Camera zoom and pane resizing must not reset
or synchronize the independently chosen logical font sizes.

## Recent preference for new panes

After decreasing B, focus the larger A without changing its font. Split A to
create C. C must start at B's last explicitly chosen size, not A's current size
or the original configured default. A and B must remain unchanged.
Increase C once. Create a new tab and a new desktop window; their new terminal
panes must start at C's last chosen size. Merely focusing or reopening an older
pane must not overwrite the recent preference. No existing shell restarts.

## Reset and persistence

Reset the focused pane with Command+0. Only that pane returns to the configured
default; this explicit reset becomes the recent preference for subsequent panes.
Change a pane again, then relaunch using the same isolated state directory. A
fresh pane must start at the most recently selected size. Session save/restore
must retain each saved pane's individual size rather than applying the recent
preference to all restored panes. Restoring old panes does not change the recent
preference for genuinely new panes.

An empty/missing or invalid recent preference falls back to configuration. The
recent preference is application state (`recent.conf`), not a rewrite of the
user's authored terminal configuration.

## Evidence and result

Capture before/after views of A and B together, the new C pane, and an independently
named tab/window. Retain actual native font/grid measurements and PIDs. Report
PASS/FAIL/BLOCKED. The deterministic replay sends real keyboard shortcuts and
checks live native terminals, session snapshots, and a fresh preference reader.
Its headless pass is not a claim of visual review or a full application relaunch;
perform the relaunch and rendered comparisons during LLM/manual execution.

```sh
uv run tests/godot/test_dashboard.py test pane-font-size
```
