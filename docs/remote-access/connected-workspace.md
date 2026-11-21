# Use a remote workspace

Once connected, programs keep running on the server. **Detach** leaves them
running. **Kill Session** ends the selected session and its programs.

## Know where data lives

- **On the server:** programs, terminal contents, Chromium profiles, files, and graph work.
- **On your device:** selected view, camera, window appearance, language, and notification preferences.
- **Explicitly closing a pane:** ends its program on the server.
- **Detaching or losing connection:** leaves programs running.

## Receive node notifications

- Nodes keep running with no client connected.
- Graph connections cannot cross server workspaces.
- Notifications appear on connected clients; clicking one focuses the associated pane.
- Disconnected clients cannot receive notifications in real time.

## Browse a remote page

- Browser processes, profiles, and cookies stay on the server across detach.
- Pages stream to the client; mouse, keyboard, tabs, and navigation work in the pane.
- Closing a browser explicitly ends it.
- Remote native-window pop-out and remote Playwright attachment leases are unavailable.
- Adjust [stream quality and profiles](../customize/chromium-profiles.md) to suit your connection.

## Android touch controls

| Gesture | Action |
| --- | --- |
| Tap | Activate a control |
| Drag a title or node output | Move a pane or connect a node |
| Drag empty workspace | Pan |
| Two-finger pinch and drag | Zoom and pan around your fingers |
| Double-tap a pane title | Fit the pane |
| Long press | Open context actions |

- Use the keyboard button to show or hide the keyboard.
- The key strip provides Esc, Ctrl, Alt, Tab, Shift, and arrows, regardless of server OS.
- External keyboards use **Ctrl+Shift+C/V** for copy/paste; **Ctrl+C** remains terminal interrupt.
- Changing servers or hiding the keyboard clears modifiers.
- Your phone's world and camera are independent of the desktop view.

## Upload files and paste images

```sh
# Upload and paste the completed path, without Enter.
gft terminal put --target 'build/%12' --paste screenshot.png

# Upload only; print the destination path and byte count as JSON.
gft terminal put -t 'build/work:1.2' --json screenshot.png
```

- Omit the target inside the destination Graffitty terminal.
- Files must be no larger than **32 MiB**.
- Paste actions also transfer clipboard images and paste their completed path.
- Partial uploads never paste a path. Completed attachments remain until their terminal closes.
- The receiving agent must support image paths as attachments.
- An SSH shell inside a local pane is not an attached Graffitty server. Connect Graffitty to the computer running the agent first.
