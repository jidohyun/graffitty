# Forwarded connections negotiate capabilities — MT-03

This is a strict requirement governed by [the suite contract](README.md).

## Exercise SSH TCP and Unix-socket forwarding

1. Use an authorized second host or isolated environment with a different
   filesystem/resource namespace. Start a private test server there and connect
   a real production frontend through an SSH TCP forward bound to local loopback.
   Record the real topology and tunnel command with credentials redacted.
2. Verify that the frontend sees a localhost endpoint but does not classify it as
   GPU/SHM-shareable based on its address. A local Unix socket is also insufficient:
   repeat using SSH Unix-socket forwarding where supported. Mark unavailable
   coverage BLOCKED with the exact platform limitation, never silently passed.
3. Require authenticated capability negotiation and an actual native resource
   exchange/import before either sharing capability can become active. Numeric
   handle values, a claimed PID, server flags and readable-looking paths are not
   proof. Ordinary SSH byte forwarding cannot transfer ancillary descriptors or
   Mach rights. Verify failed exchange/import is detected with bounded time and
   an explicit recorded fallback reason; no hang or crash is acceptable.
4. Open the animated chromium fixture and a Kitty image in the real frontend.
   Verify continued rendering and input using the portable transport. Chromium
   fallback must negotiate a supported video codec; automatic JPEG/PNG chromium
   fallback is forbidden. If no video codec is usable, report an explicit
   unsupported-transport error rather than silently selecting JPEG/PNG.
5. For Kitty, verify the server resolves a fixture path that does not exist on the
   client and delivers a portable representation. The client must not open the
   remote path or interpret a remote handle number as a local handle. Remote PNG
   delivery is allowed here; MT-02's no-repeat-decode rule applies to the supported
   same-host pixel-sharing path. Delete the source, reconnect, and verify retention.

## Exercise independent capability failure and renegotiation

1. On a supported same-host configuration, verify both native GPU import and SHM
   mapping independently. Then use a controlled failure injection at the real
   import boundary: fail GPU import while permitting SHM, and fail SHM mapping
   while permitting GPU. Record the injection and actual attempted operation;
   changing a UI label or fabricating a negotiation response is not sufficient.
2. Verify GPU failure selects chromium video delivery while Kitty can still use
   verified SHM or decoded pixels over IPC. Verify SHM failure does not disable a
   working GPU path; Kitty can use decoded pixels over IPC. Never treat one
   capability's success as proof of the other.
3. Reconnect through a different topology (native local connection, then tunnel,
   then local again). Verify fresh negotiation, no stale handles/cached locality,
   correct resource cleanup and preserved server-owned chromium/PTY state.
4. Review continuous frontend recordings plus negotiation/import/fallback evidence.
   Report results separately for TCP forwarding, Unix forwarding and independent
   import failures. A mocked connection or a same-host byte relay alone cannot
   certify cross-host resource isolation. Missing coverage remains BLOCKED.
