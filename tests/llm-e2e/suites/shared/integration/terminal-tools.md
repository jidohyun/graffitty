For Godot on Windows, run `python tests/platform/windows/windows_private_replay.py --replay tests/llm-e2e/suites/godot/integration/replays/terminal-tools.gd --evidence <new-directory>` with a frozen project. This uses a private raw-mode PTY; do not type into the human's desktop window or read their clipboard.

## Search and navigate

Inspect `terminal-search.png`: the literal word must be highlighted in an actual historical terminal row, the footer must show the query and match count, and the scrollbar must reflect the revealed match. Confirm `copy` returned exactly `needle`, including after moving to a previous result.

## Select and copy

Inspect `terminal-copy-mode.png`: the keyboard selection must cover exactly `TOOLS` in `TOOLS_READY`. It must not include the pane title or adjacent blank cells. Accepting it exits copy mode and copies those five characters.

Inspect `terminal-quick-select.png`: a legible gold label must appear on the visible URL. Type that label through the frontend's keyboard route and check the exact copied URL. An uppercase label deliberately pastes the URL into the raw PTY.

Require the fixture's final `TOOLS_BYTES_...` response to contain only that explicitly pasted URL. Search text, arrow keys, escape, copy-mode movements and corresponding releases must not appear. The same shell PID must survive. Verify semantic copy-last-output returns the marked output and excludes prompt/command text.

State assertions and gold-pixel counts do not replace image inspection. Record actual inspected paths and any legibility/cropping failures in a separate `visual-review.json`; do not mark an unreviewed capture visually passed.
