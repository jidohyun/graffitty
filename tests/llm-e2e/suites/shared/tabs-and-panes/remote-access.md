Launch without remote options. Verify remote access is off. Toggle Sessions → Remote Access on; verify a loopback client can connect. Toggle off; verify the client disconnects and the network endpoint disappears while the private server descriptor remains. Toggle on again and verify the token changed. Local terminal processes must survive every toggle. With enabled = true under [remote] in server.toml, sharing must instead start automatically and remain stoppable from the menu.

Bind-address support is a strict requirement, independent of the network provider.
Repeat with an assigned non-loopback interface address and with the explicit
wildcard `0.0.0.0`. Require the listener to bind exactly the requested address,
an authenticated client to reach the same retained PTY, and the toggle to stop
that listener. A wildcard listener is reached through a concrete host address.
Use an isolated test owner; never replace the user's active listener. No special
Tailscale detection, loopback-only restriction or silent fallback to another
interface is permitted. An invalid or unavailable address must fail explicitly
and preserve any previously working listener and local PTYs. Default startup
still leaves network sharing off unless explicitly enabled in configuration.
