For Godot on Windows, run `python tests/platform/windows/windows_input_acceptance.py --suite input
--evidence <new-directory>`. It uses private real PowerShell/ConPTY shells and
Godot viewport events. Keyboard shortcuts come only from `client.toml`
`[bindings]`; an empty array unbinds an action so its key reaches the PTY,
`SendText = [{ key = "F6", text = "…" }]` sends exactly that text and
`Ignore = ["F7"]` sends nothing. The
app's Edit → Input Settings dialog provides Apply, Cancel, mouse bindings and
scroll speed. The fixture covers rejected typed settings without restarting
shells. Inspect
`settings/input-settings.png`, `wheel/half-row-font-{16,24,32}.png` and
`mouse-controls/mouse-binding-search.png`; the last capture shows the literal
query and real highlighted matches. `--project <isolated-project>` selects an
isolated extension build. For targeted follow-ups, use the individual cases in
`tests/platform/windows/windows_input_routing_e2e.py` and retain existing unaffected evidence.
Do not send desktop input or use the system clipboard.

Verify actual accumulated PTY bytes, including key releases. A custom Unicode text binding must send only its configured text; ignored keys send nothing; a removed default binding reaches the terminal normally. Leader sequences and multi-key sequences consume constituent keys, one-shot tables pop, expired tables pass the ordinary key, and the configured workspace prefix consumes its prefix keys. Open real terminal search through a configured key, type the query through the frontend's keyboard route, and cancel using a remapped modal key. These local keys must not enter the raw PTY.

At font sizes 16, 24 and 32, two 7.5 px wheel motions must produce one row of history scrolling, with the first preserving a half-row. A discrete wheel notch scrolls three rows. Check a multiplier of 2 and a disabled multiplier of 0. In the actual alternate screen, no arrow bytes may be sent when ALT_SCROLL is disabled; with ALT_SCROLL enabled, two fractional events send exactly one arrow. In SGR tracking mode, require the exact wheel packet at the projected cell, and three packets for a discrete notch.

Inspect the search, wheel and Input Settings captures. Search must show the literal query with real matches. Fractional content must remain legible without squeezing or dropped rows. The actual Input dialog must be contained and readable, with the configured bindings and speed visible. Invalid typed settings must preserve the working config and original PTY process. Report unexpected bytes or clipped UI as failures; do not substitute state-only telemetry for image inspection.

Save a separate `visual-review.json` naming each image actually inspected and the frozen binary digest. These injected events do not establish physical trackpad event delivery or OS-level shortcut behavior.
