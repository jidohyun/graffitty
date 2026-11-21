# Build, installation, and permission acceptance

## OP-01 — Current upstream host, scoped macOS port

The work uses sibling `../lumen`, `../sunshine`, and `../artemis` repositories.
Record the exact upstream commit and the port branch; "latest" must be dated or tied
to a hash. Keep current upstream fixes rather than reintroducing old snapshot code.
Build the macOS host, helper, Web UI, and relevant tests before claiming it runs.

Preserve existing user configuration and the separately installed Sunshine. Do not
run an installer that silently overwrites those settings. Optional virtual-gamepad
features requiring weakened macOS security are not part of the office baseline.

## OP-02 — One installed Lumen identity

Install the streaming host in place as `/Applications/Lumen.app`, displayed as
**Lumen**. Its bundle metadata, embedded executable metadata, signature identifier,
launcher, running process, and permission requests must agree. Do not leave a second
staged/test copy confusing Launch Services or the permission picker.

Keep credentials/state in the appropriate user application-data location, not the
repository. Verify launch from Applications without relying on a temporary build
folder and preserve established login/pairing state where the current schema permits.

This is the Lumen companion-host requirement, not a change to Graffitty's own
installation path in `AGENTS.md`.

## OP-03 — Permissions are verified, never assumed

After installation/rebuild, query the running host's permission status and verify
which executable is running. Check Screen Recording and keyboard/mouse access
separately. Restart without rebuilding to test newly applied consent.

Ad-hoc signing may invalidate prior approvals. If needed, reset only Lumen's stale
records with supported tools, open the correct settings pane, and reveal the installed
bundle. The user must grant access. Do not edit permission databases, disable macOS
security, automate consent bypass, or remove unrelated Sunshine approvals.

Pass requires both host-reported permissions and a functioning captured stream/input
path. A visible toggle or a successful launch alone is insufficient.

## OP-04 — Android deployment and connection

Install the Artemis fork on both designated development devices, verify package/build
identity and saved preferences, and pair through the host's authenticated PIN flow.
Use standard host/stream discovery and distinguish its streaming endpoint from the
Web UI. Do not commit pairing codes or host/device addresses.

For baseline testing, explicitly record resolution, frame rate, codec, HDR, bitrate,
mouse mode, IME, and commit-text configuration. Then test the real Android client:
a host build or encoder-detection message does not establish a working connection.

Keep an authorized test device awake while charging if needed, but do not remove or
bypass its lockscreen credential. If locked, ask for an unlock and report the test
blocked. Do not switch/install keyboards on unrelated devices without authorization.
