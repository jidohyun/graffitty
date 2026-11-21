# Remote access

Use another computer's terminals, browsers, and agents from desktop or Android.
Programs keep running there when you disconnect.

## Connect with SSH

If you already use SSH, prepare a [server bundle](../developers/build-and-run/remote-server.md), then run:

```sh
gft remote connect user@computer
```

For address and tunnel behavior, see [connection settings](connection-settings.md#connect-over-ssh).

## Connect with Tailscale or a trusted network

On the computer running your sessions:

1. [Choose a listening address](connection-settings.md#listen-on-the-right-network).
2. Open **Sessions → Remote Access** to enable sharing.
3. Open **Sessions → Remote Access Settings…** to view or set the password.

On your other device:

1. Open **Sessions → Servers… → Add server**, or **Add server** on Android.
2. Enter the server address and password.
3. Leave the session name blank to resume the previous session.

Sharing is off by default. The menu toggle lasts for the current launch.
Android requires a server; it has no local terminal mode.

## Leave safely

**Disconnect** or **Detach** leaves programs running. To end one session and its
programs, right-click it in the **Sessions** list and choose **Kill Session**.
Other sessions keep running. A server with remote access enabled stays online
even after its last session ends. A private server exits when its last session ends.

Turning sharing off disconnects remote clients while local sessions continue.
Input typed during a network outage is discarded.

## Next steps

- [Passwords and optional login codes](authentication.md).
- [Saved servers and remote CLI targets](saved-servers.md).
- [Browsers, Android controls, and uploads](connected-workspace.md).
- [Encryption details](connection-settings.md#understand-encryption).
