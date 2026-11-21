# Remote connection settings

Configure these on the computer running your sessions.

## Listen on the right network

Edit `~/.config/graffitty/server.toml`:

```toml
[remote]
enabled = true
bind_address = "127.0.0.1"
port = 7183
```

- `127.0.0.1` accepts local connections and SSH tunnels only.
- For Tailscale, run `tailscale ip -4` and use that computer's address.
- `enabled = true` starts sharing automatically; otherwise use the menu toggle.

Apply edits with a [server restart](../customize/server-configuration.md#reload-server-configuration).
An unavailable address prevents sharing. Update the setting if its Tailscale address changes.

## Enter a server address

A bare hostname uses `ws://` on port **7183**. An explicit `wss://` address uses
TLS and defaults to **443**.

Leave the session name blank to resume the remembered or server-selected session.
A name selects or creates a session; it does not restrict access to that session.
Saved passwords enter the device credential store after successful login.

## Understand encryption

Terminal data and verification codes are encrypted after login, including over
`ws://`. OPAQUE verifies the password without sending the password itself.

On `ws://`, setup metadata and framing remain visible. Use trusted TLS,
Tailscale, or SSH for additional protection. Addresses, timing, and traffic sizes
can still be observable.

## Connect over SSH

```sh
gft remote connect user@computer
```

Prepare a [matching server bundle](../developers/build-and-run/remote-server.md)
for the remote OS and CPU. OpenSSH handles authentication, host-key checks,
and SSH aliases. Existing shells are reused.

The client keeps the tunnel open and retries dropped connections. Closing it
closes tunnels while remote shells continue. A remote reboot ends the programs;
the server is not installed as a boot service.

For several hosts, pass their SSH aliases together:

```sh
gft remote connect build-server home-pc laptop
```
