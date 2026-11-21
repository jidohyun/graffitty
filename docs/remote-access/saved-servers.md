# Saved servers

Manage connections after [setting up remote access](index.md).

## Several computers at once

Use **Sessions (<img class="menu-icon" src="../images/menu/panels-top-left.svg" alt="" width="18" height="18">) → Servers…** to manage saved computers.

| Action | Result |
| --- | --- |
| Open in new window | Keep it beside the current workspace |
| Return to This Computer | Return to local programs without restarting them |
| Disconnect | Keep the saved server and its running sessions |
| Remove | Forget the bookmark and saved password; does not stop the server |

- Switching servers restores each view's selected session, tab, pane, and camera.
- Temporary network loss leaves the workspace visible with offline status while retrying.
- Input typed offline is discarded, not replayed later.
- Android can reconnect its last server when remembered credentials are available.
- **Detach** keeps programs running. **Kill Session** ends the selected session and its programs.

### Target a remote pane from the CLI

Saved servers have a stable CLI alias. Change it in **Server alias (CLI, optional)**.
With alias `build`:

```sh
gft pane list -t build/
gft terminal type -t 'build/%12' --text 'hello'
```

Use the pane IDs returned by `list-panes`. The target needs no network port.
