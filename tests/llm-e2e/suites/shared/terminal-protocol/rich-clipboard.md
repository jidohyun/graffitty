For Godot Windows, run `python tests/platform/windows/windows_rich_clipboard_e2e.py --evidence <new-directory>`
(optionally `--project <isolated-project>`). This uses a separate Windows window station
and native clipboard, never the interactive user's clipboard. Record the reported
elevation and the exact extension/owner hashes. Inspect `rich-clipboard-consent.png`
for the requesting pane and actual pointer-driven Deny/Allow once controls. Require
the exact raw ConPTY receipt in `report.json`. Windows has no native primary
selection; require the reported capability and exact `ENOSYS` replies for it.
The separate `windows_clipboard_native.rs` fixture checks native Unicode/PNG
interoperability, and `clipboard_owner_e2e.py` checks exclusive routing,
stale replies, disconnect, and reconnect without any OS clipboard operations.
Keep existing user windows, PTYs and the OS clipboard untouched.

User-initiated image paste is separate from the OSC clipboard protocol below.
It uploads bounded image bytes to the pane's Graffitty server and pastes the
completed path. See `tests/e2e/input.md` IN-09 and the existing
`android-bracketed-paste` scenario for mobile and remote acceptance.

Require exact live raw-PTY bytes for Unicode, a PNG larger than 128 KiB, aliases,
independent primary selection, format enumeration, permission denials and stale
consent after a VT checkpoint. Retain failures; state alone is not transfer proof.

Open `rich-clipboard-consent.png`. Check the requesting terminal is identified
and the actual Deny and Allow once buttons are legible and contained. Confirm
the trace uses real pointer down/up events for Allow once.

Write `visual-review.json` referencing `report.json` and its exact executable
SHA. Record only the observed scope. This isolated private clipboard test does
not establish native OS clipboard interoperability.
