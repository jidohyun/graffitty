On Windows, run the server subset with each shell against an explicitly selected build:

Godot's **Shell → Session Defaults** exposes the scrollback byte budget, Kitty
storage/upload limits, and automatic shell integration for future local panes.
Blank uses the server default; zero history or storage disables that retention.
These controls leave existing panes unchanged. The Godot Windows adapter runs
real PowerShell hooks and launches a second frontend process against the same
private owner to verify checkpoint history, image policy and shell identities.
Review its captures and the separate server subset below together.

```powershell
$env:GRAFFITTY_TEST_SERVER = (Resolve-Path target/debug/gft.exe).Path
uv run --no-project --with websocket-client python tests/platform/windows/windows_launch_policy_e2e.py --shell powershell.exe --evidence .cache/windows-e2e/launch-policy-ps51
uv run --no-project --with websocket-client python tests/platform/windows/windows_launch_policy_e2e.py --shell pwsh.exe --evidence .cache/windows-e2e/launch-policy-ps7
```

Use fresh evidence directories. This subset observes real shell PIDs, literal
Unicode environment values, working directories, 64-byte/16-MiB/zero history
budgets, rejected spawn options, and retained history and input after a new IPC
client attaches. Reports retain the executable hash, shell receipts and actual
history. It does not certify shell semantic selection, frontend checkpoint
reconstruction, image rejection, or GUI controls and pixels; those requirements
below remain open until exercised through the relevant frontend.

Automatic semantic markers must come from a real zsh launched with the shared shell hooks. Copy Last Output must select the completed command output exactly, without a test injecting OSC133. The original startup file must remain unchanged. A second zsh with integration disabled must not produce that semantic selection.

Configure `scrollback_bytes: 64`, write 5000 complete lines, and verify older output is evicted while recent lines remain. Repeat the same output with a 16 MiB budget and require both its first and last lines to survive, proving the budget changes real retention. This is a byte budget rounded to engine pages, not an exact row count or overall process-memory ceiling. Both configuration and topology/checkpoint limits use `scrollback_bytes`; the old spelling is rejected. Change future-session defaults to zero history and zero Kitty image storage. Zero must also leave the scrollback viewport offset at zero. Existing PTYs and their resolved limits must remain unchanged. A newly created pane must reject the red test image while continuing to display ordinary shell output. Settle the headless camera flight and require the truecolor green identity line on the tested terminal before comparing image pixels. Inspect the paired image captures rather than trusting only metadata.

Repeat the rejected upload after live application RIS, once in one write and once with ESC and the rest of RIS in separate writes. Require the green identity marker and absence of the red image on both actual captures; a metadata-only zero limit is insufficient. Close the frontend while the private session owner continues running. Attach a fresh frontend and verify the same PIDs, restored resolved policies, retained recent output and new typed input. Require the larger retained history to match exactly before and after checkpoint reconstruction, with no invented blank rows. Inspect the final whole-UI capture for readable text and pane/header alignment, and the real Session defaults dialog for the byte-budget label and page-rounding/zero-history hint. Record hashes and a separate visual-review.json. This proves frontend checkpoint reconstruction, not stopped-server process resurrection or an overall process-memory ceiling.
