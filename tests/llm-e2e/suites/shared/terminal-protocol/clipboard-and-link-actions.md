For Godot Windows, run `python tests/platform/windows/windows_protocol_actions_e2e.py --evidence <new-directory>`
(optionally `--project <isolated-project>`). The outer launcher creates a private
Windows window station, and the worker verifies it before starting both the
session owner/ConPTY and Godot. It never falls back to the user's clipboard.
Retain `report.json`, `owner-build.json`, `osc52-ask-dialog.png`, and
`terminal-hyperlinks.png`; record the isolated station and reported elevation.
The raw receipt must include original BEL/ST replies and omit denied, reused,
and stale requests. Closing the requesting pane must destroy its consent while
the unrelated original shell remains alive. Link clicks use projected Godot
pointer events with external URL opening disabled.
Never substitute the human's system clipboard or synthesize desktop clicks.

## Inspect clipboard consent

Inspect `osc52-ask-dialog.png`. The real modal must identify the requesting terminal and present readable Deny and Allow once buttons. It must dim the underlying workspace without obscuring its own controls. Clipboard contents must not appear in the prompt.

Require the exact raw PTY replies for accepted requests, including Unicode base64 payload and original BEL/ST terminator. Denied requests must not receive clipboard contents. Switching off terminal clipboard writes must preserve the prior private clipboard value. State-only consent flags are insufficient proof.

## Reject stale consent and activate links

Reject reused request IDs, a request whose terminal's VT has been replaced, and a request from a closed pane. A subsequent request must require its own fresh decision. These operations must preserve unrelated shells and must not access a native credential or clipboard store.

Inspect `terminal-hyperlinks.png`, then require projected Ctrl/Cmd clicks to select the exact OSC 8 target and the visible plain URL, including when the displayed link text differs from its URI. Headless activation must record the target without opening a chromium or external application. Unsupported URI schemes and disabled-link policy must not launch anything.

Record actually inspected artifacts in `visual-review.json`. Keep any failed run and its executable hash; a retry does not erase earlier failure evidence.
