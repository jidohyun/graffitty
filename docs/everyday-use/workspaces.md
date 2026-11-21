# Tabs and panes

A tab groups related terminal, browser, and filetree panes.

## Create and arrange panes

| Task | Action |
| --- | --- |
| Split right/below | Click the split buttons in a terminal title bar |
| Split left/above | Right-click those buttons |
| Resize tiles | Drag a shared border; a shared corner changes both directions |
| Resize floating panes | Drag an edge or corner |

New panes tile inside Main and inherit the source directory.
Each tab keeps its own tiling and [spacing](../customize/configuration-workspace.md#adjust-pane-spacing).

## Keep less-used panes nearby

1. Zoom out to see the Main border.
2. Drag a pane outside to stash it without closing.
3. Drop it onto a tile to return; the preview shows placement.

Double-click a title to fit its pane. **View → Fit to Main Area** returns to Main.
**View → Floating Pane Physics** lets floating panes push neighbors; disable it
to overlap them manually.

## Organize tabs

The prefix is **Ctrl+A**, released before the next key.

| Task | Action |
| --- | --- |
| New / next / previous tab | Prefix C / N / P |
| Find tab or pane | Prefix V |
| Reorder tab | Drag along tab bar |
| Move pane to existing tab | Hold title over tab, then drop into its content |
| Give pane a new tab | Drop title on tab bar |
| Move tab to a desktop window | Pull it outside the app |

Connected groups move together, including attached browsers/filetrees.
See [window transfers](multi-window.md).

## Related tools

| Need | Open |
| --- | --- |
| Browser | Chromium button in terminal title bar; each click creates a session. From a terminal outside the Main view, it opens to the terminal's right |
| Saved browser logins | [Profiles](../customize/chromium-profiles.md) |
| CPU/memory across panes | View → Resource Monitor |
| Focused pane details | View → Pane Status, or its context menu |
| Hide/restore side panels and status bar | Cmd+B on macOS/iOS; Ctrl+Shift+B elsewhere |
| Leave programs running | [Sessions](sessions.md) |
| Save a layout for later recreation | [Checkpoints](checkpoints.md) |

Panel positions return when shown again.

To resize one panel's text and controls, point at it and press the font size keys (Cmd+Plus, Cmd+Minus, Cmd+0 on macOS; Ctrl elsewhere). Each panel keeps its own size, and it is remembered with the panel's position. With the pointer over a terminal, the same keys change that terminal's font size. View → Toggle Side Panels offers the same toggle.

## CLI

```sh
gft tiling layout h_tiles
gft tiling balance-sizes
gft tiling view overview
gft tiling view main
```

`gft pane select -L/-D/-U/-R` includes floating neighbors;
`gft tiling focus left` stays tiled. Use `gft tiling --help` for options.

## Starting directories

`gft-gui --cwd /path/to/project` sets the launch directory.
Splits inherit their source and new tabs inherit the active terminal's directory.
Remote paths belong to the server filesystem.
