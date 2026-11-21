# Touch controls and terminal title masking

Connect to a Mac server, then a Windows or Linux server. The accessory keyboard
always offers Esc, Ctrl, Alt, Tab, Shift and arrows; it never requires Command
or Option. Open Shell, Edit, View and Sessions. Verify New Tab, New Chromium,
new panes, Close Pane, Copy, Paste, Find, Overview, Fit to Pane and Messages are
available. Use an external keyboard: Ctrl+Shift+C/V copy/paste while plain Ctrl+C
still interrupts the terminal. Activate a new pane through the menu.

Run a terminal application with a status line at the bottom. Zoom out until the
title grows over the top rows and the icons disappear, then zoom back in. The
terminal content must not shift or shrink. Its last row stays visible, the grid
size stays unchanged, and only the top rows are covered by the title. Inspect
actual rendered pixels, not just visibility flags. Repeat with the keyboard open.

The automated shared scenario checks menu coverage, modifier hints, unchanged
terminal geometry/grid, and rendered coloured text on the bottom row across zooms.
