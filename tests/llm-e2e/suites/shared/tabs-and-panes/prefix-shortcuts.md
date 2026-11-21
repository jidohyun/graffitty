# Workspace prefix shortcuts

The default prefix is Ctrl+A on every platform, including macOS and iOS.
Custom `client.toml` prefixes still take precedence.

Open ten tabs. Press Ctrl+A: the selected tab changes color. Type 1 then 0:
neither digit switches tabs until Enter, which selects tab ten. Cmd+1 still
selects tab one immediately, and Cmd+9 selects the last tab (tab ten here, not
the ninth).

Press Ctrl+A then C to create a tab. Use prefix then backslash to split right,
H/L to focus left/right, minus to split below, and K/J to focus up/down.
Verify pane positions and focus in the recording. Shifted pipe splits left;
shifted underscore splits above, matching the current directional bindings.

While armed, Escape cancels and restores the tab color. Backspace edits the
tab number; an invalid number or unbound key must not leak into the shell.
Verify custom prefix and binding configuration works. Focus loss should clear
prefix mode. Report failures with the replay and observed state.
