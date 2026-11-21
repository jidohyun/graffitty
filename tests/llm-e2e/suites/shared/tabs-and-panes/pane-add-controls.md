# Directional pane creation

All terminal panes show the right and below creation icons. There is no separate
pane plus button. Ctrl+A then backslash creates right; Ctrl+A then minus creates below.

In floating mode, use each direction: a live terminal appears touching that side
of the source in the same tab. The source stays anchored while physics pushes the
new pane outward. Floating mode and existing shells must be preserved.

Enable tiling and use the same icons: new panes split the selected tile. Stash a
pane outside Main and create below it: the new pane stays floating outside Main,
without changing managed tiles. Verify focus moves to each new pane and original
shell PIDs remain unchanged. Cmd+T creates a tab; Cmd+N creates a native window.
