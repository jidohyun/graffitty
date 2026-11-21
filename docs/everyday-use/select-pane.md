# Select a pane from the command line

Find a pane, then focus it:

```sh
gft pane list
gft pane select -t %3
```

Replace `%3` with a returned ID. Selection reveals hidden panes and switches
tabs within the calling window. With no flags, the calling terminal is selected.

## Choose a neighbor

```sh
gft pane select -L
gft pane select -t %3 -R
```

Use one direction: `-L`, `-D`, `-U`, or `-R`.
Neighbors include shown floating panes in the starting tab, even outside Main View.
Navigation stops at the edge.

## Other targets

`-t :1.2` selects pane 2 in tab 1. See [terminal commands](terminal-commands.md)
for remote targets. To stay inside tiled panes, use `gft tiling focus left`.

[Neovim and tmux navigation](../customize/nvim-tmux-navigator.md) uses the same
outer-edge selection behavior.
