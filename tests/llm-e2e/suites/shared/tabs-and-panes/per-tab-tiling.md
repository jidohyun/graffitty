# Tiling defaults and per-tab isolation

Use the existing `per-tab-tiling` replay with isolated sessions. Record PASS,
FAIL, or BLOCKED with layout and process evidence.

## User-facing defaults

- Fresh tabs start tiled.
- Neither **View → Tiling** nor **View → Tiling for New Tabs** appears in the menu.
- Adding panes tiles them automatically; dividers resize them.

## Internal floating-layout coverage

The retained tiling APIs still support floating layouts. Exercise these through
the replay's `toggle_tiling()` and `set_default()` helpers, not menu actions.

1. Create ALPHA and BETA with two terminals each and different split proportions.
2. Disable floating-pane physics and record layouts and shell PIDs.
3. Toggle each tab independently. Floating panes retain their positions; tiled
   panes retain their split layout. Switching tabs must preserve each mode.
4. Change the internal future-tab default. Existing tabs must remain unchanged;
   only newly created tabs inherit it.
5. Toggle a new tab locally, then create another. The local toggle must not
   alter the future-tab default.
6. Repeat with both enabled and disabled defaults.

Every original shell must retain its PID and accept fresh input. No mode change
may recreate a shell or move a pane to another tab. Restore the default and close
the test sessions afterward.
