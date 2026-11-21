# Android list docking and presentation isolation

Use the existing disposable Android-runtime client/server fixture. Open Agents
and Sessions through registered commands. Inject touch through the viewport:
resize the embedded window at its real corner, drag its title into the main-content
edge, then stack the other window above it. Resize dock width and stack height with
the invisible touch dividers, starting at the center and both edges of the full
configured gap. No horizontal bar, floating resize border or corner triangle is
painted. Agents/Sessions use dense spacing with no empty footer; Add server is
absent on mobile. Shrink to a compact 44-pixel strip without arrow buttons,
then expand by dragging its inner resize edge. Tap an expanded panel's title to
fold only its body; tap again to restore its stack height. Repeat while floating:
the title stays in place and unfolding restores the window size. A canceled tap
and a drag that returns to its starting point must not toggle folding. Close and
reopen a folded panel and verify its folded state survives. Repeat at 1×/1.5×,
Verify it can shrink to 40 pixels. The floating title is inside the borderless
window; touch and its emulated mouse event must count as one gesture.
Repeat title dragging at non-integer UI scale, checking logical pointer position
and one-to-one movement before entering and after leaving a preview. Undocking
must follow the finger before release. Open the ellipsis menu with a dock present:
menu and floating controls must remain above it. Verify OS icons in Sessions.

Repeat shared window/docking operations with Resource Monitor: open from the pane
menu or View menu, select/copy a readout while new samples arrive, resume updates,
and shrink/expand its CPU/memory rail. Stack it with Agents/Sessions and check that
refreshes do not change placement or send touches to the workspace underneath.
After a stack settles, leave it untouched and verify there are no continuing dock
reflows. Change a resource sample, pane inventory and connection state: each mod
must refresh from the corresponding notification without a periodic refresh.

Status Line uses a dock-only bar. Verify content without title/close chrome,
inner-edge height resizing, and background dragging between bottom and top.
Clicks/double-taps and dropping away from either edge must keep it docked and
unfolded. Its feature buttons still act normally. Use View → Status Line to
hide/show it, retaining placement and height. These bar-specific assertions
also run in `tests/status_line_smoke.gd -- --android`; that desktop touch
injection is not a physical-device pass.

Leave one panel docked and one floating. Enter the real connection manager: neither
window, dock, nor workspace may remain visible. Return and verify both presentations
are restored. Close them without disconnecting or destroying the original PTY.

This covers automated touchscreen events on the recorded device, not physical
finger feel or other display geometries. Also check UI-07/UI-08/UI-09 in
`tests/e2e/controls.md` for keyboard, rotation, persistence and multi-device acceptance.
