# Prefix command line

Open three tabs. Press Ctrl+A, then `:`. A command line opens at the bottom of
the window with every menu command listed above it. While it is open, Cmd+T
and Cmd+W must do nothing, and nothing typed into it may reach the shell.
The popup fits its content so shortcuts stay near command descriptions, grows
to the window width for long content, and shrinks when filtering removes rows.
Command descriptions show the localized command label, without menu paths such
as `View › Cursor Trail › Smear`; that command shows `Smear` beside `CursorTrailSmear`.
Its hint uses the last tab and that tab's last pane: `3 tab · 3.1 pane` initially,
or `3 tab · 3.3 pane` if the third tab has three panes.

Type `newpaner`: `NewPaneRight` ranks first, with the typed characters highlighted.
Command names are the PascalCase action names used in `client.toml`; case,
spaces and dashes are ignored. Enter splits the pane right and closes the line.

Press Ctrl+A, `:`, then `nwpnrgt`. It matches only fuzzily, so Enter keeps the line
open and says why. Tab previews the top match in the line; Escape closes it
without running anything.

From the second tab, press Ctrl+A, `1`, `.`, `2`, Enter: the first tab's second
pane takes focus, because tabs and panes are both numbered from 1. Ctrl+A followed
directly by a pane's `%ID` and Enter focuses that pane.

In Overview, each status strip shows its ordered pane number alongside its
stable ID, for example `.1 (%4)`. Run `FitToMainArea` in the command line:
the camera animates back to the fitted main area. Report failures with the
replay and the observed state.
