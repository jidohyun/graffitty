# Workspace windows

## Move work between windows

| Action | How |
| --- | --- |
| Put a tab in its own window | Drag it outside the tab strip, or choose **Move Tab to New Window** in its context menu |
| Move a tab into another window | Drop it on that window's tab strip |

- Dragging a window's only tab moves that window.
- Transfers work within one running application.
- Processes and scrollback survive the move.
- Terminals carry their attached browsers with them.
- For pane arrangement, see [tabs and panes](workspaces.md).

## Close a window

Clicking × in a connected window asks first:

- **Detach:** close the window; its session and programs keep running.
- **Kill Server:** stop the local server and end every session it hosts. Available in windows connected directly to that server.
- **Cancel:** keep the window open.

A private server stops when its final session ends. Detached sessions with live
panes keep it running. A server with remote access enabled stays online without sessions.
See [sessions](sessions.md) for all closing options.

## Appearance and performance

- New detached windows inherit the source window's world.
- Moving into an existing window uses that window's appearance.
- More visible windows require more rendering work and memory, even though they share loaded assets.
- An unfocused window does not lower a focused window's frame limit.

## Window corners and decorations

Linux workspace windows use Graffitty's tab strip as their title bar by default
(`decorations = "client"`). Drag empty space in the strip to move the window,
double-click to maximize or restore, and drag an edge or corner to resize.
GNOME's button layout sets the placement of minimize, maximize and close.

Floating windows round all four corners with a 12-logical-pixel radius scaled
to the display. On X11 this requires a 32-bit window visual with alpha and an
active compositor. On Wayland the presentation surface must support alpha.
Opaque windows have square corners and a one-pixel border. Maximized, fullscreen and
compositor-reported tiled windows fit their available space without resize margins.

To use your desktop's title bar, set this in `client.toml` and reopen the frontend.

```toml
[window]
decorations = "system"
```

Windows 11 chooses the visible corner treatment. Graffitty requests rounded
corners for workspace windows, floating panels and tab drag previews, and
smaller corners for popup windows.
