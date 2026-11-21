# Native Windows acceptance

These cases supplement the shared functional suites on the Windows desktop.
They require every Windows frontend; another platform reports NOT_APPLICABLE,
and a missing Windows adapter remains BLOCKED. PowerShell 5.1 and PowerShell 7
have separate procedures and evidence, even when the application build is the
same. PowerShell 7 is the main demo shell.

| Case | Windows-specific requirement |
| --- | --- |
| powershell-51 | Windows PowerShell 5.1 startup, Unicode, cwd, filetree, input and hooks |
| powershell-7 | PowerShell 7 startup, Unicode, cwd, filetree, input and hooks |
| conpty-interactive | Loaded ConPTY 1.25, terminal queries, mouse modes, image detection and node keys |
| chromium-native | Verified D3D12 frames, tab lifetime, native window focus and return to embedded presentation |
| pane-titles | Working-directory and application titles in normal PowerShell 5.1/7 panes, with integration on/off |
| elevated-pane-titles | The same title matrix under an explicitly elevated Windows token; localized Administrator prefixes never replace the cwd |
| korean-ime-dpi | Physical Korean IME, 150% DPI, native focus, window movement and Chromium presentation |

Follow each Markdown procedure and save continuous recordings plus a review
record identifying inspected frames. The two PowerShell Godot replays check
version, real PTY output, Unicode paths and Ctrl+C with shell PID continuity.
The ConPTY replay runs a console probe under both PowerShell versions, saves
the exact OSC color replies and SGR wheel bytes, and drives wheel events through
the Godot input route. It does not create a separate Python PTY.
Their declared coverage gaps retain the physical-input and filetree review;
no deterministic replay currently certifies all requirements.
The following commands provide supporting automated evidence:

```powershell
mise run test:shared:catalog
python tests/platform/windows/test_windows_hooks.py -v
python tests/platform/windows/test_windows_hooks.py WindowsHooks.test_windows_powershell_51_hooks -v
python tests/platform/windows/test_windows_hooks.py WindowsHooks.test_powershell_7_hooks -v
python tests/platform/windows/windows_pane_titles_e2e.py --elevated false --evidence .cache/windows-titles-normal
python tests/chromium/desktop_defaults_godot_e2e.py --evidence .cache/windows-desktop-defaults
python tests/platform/windows/windows_multisession_e2e.py --shell powershell.exe --evidence .cache/windows-multisession-ps51
python tests/platform/windows/windows_multisession_e2e.py --shell pwsh.exe --evidence .cache/windows-multisession-ps7
python tests/platform/windows/windows_input_routing_e2e.py --case keys --evidence .cache/windows-input-keys
python tests/platform/windows/windows_input_routing_e2e.py --case mouse --evidence .cache/windows-input-mouse
python tests/platform/windows/windows_input_routing_e2e.py --case mouse-protocol --evidence .cache/windows-input-protocol
python tests/platform/windows/windows_input_routing_e2e.py --case wheel --evidence .cache/windows-input-wheel
python tests/platform/windows/windows_input_routing_e2e.py --case wheel-protocol --evidence .cache/windows-wheel-protocol
uv run tests/godot/test_dashboard.py test --headful --suite windows
$env:GRAFFITTY_TEST_SHELL = 'powershell.exe'
python tests/server/test_last_session_shutdown.py -v
python tests/godot/tab_window_e2e.py --scenario close --gpu --evidence .cache/windows-close-ps51
uv run tests/godot/test_dashboard.py test --headful --suite filetree
$env:GRAFFITTY_TEST_SHELL = 'pwsh.exe'
python tests/server/test_last_session_shutdown.py -v
python tests/godot/tab_window_e2e.py --scenario close --gpu --evidence .cache/windows-close-ps7
uv run tests/godot/test_dashboard.py test --headful --suite filetree
```

An automated hook pass does not establish interactive shell, IME or video
acceptance. Keep PASS, FAIL, BLOCKED and NOT_APPLICABLE separate in reports.
Record unexecuted procedures as INCOMPLETE rather than implying an external
blocker. The elevated title adapter must run from an already elevated shell;
it never elevates itself. Run it with `--elevated true` and a fresh evidence directory.
The shutdown fixture retains native process handles before closing shells and
checks natural owner exit before cleanup. Unix Ctrl+D EOF is not applicable to
the Windows console; Windows runs pane/tab/CLI closure and explicit shell exit.
The multi-session GUI fixture starts through the production launcher, closes a
two-pane final tab, verifies a detached workspace retains its shell and output,
then closes that last workspace and observes natural owner shutdown. It adds
that specific GUI route; it does not replace the full close-route matrix.
Use `--route pane-menu`, `pane-shortcut`, `shell-exit`, or `cli` for other
closure paths, and `--multi-tab` for intermediate tab survival or multi-tab
session deletion. Closed-session queries must reject without recreating shells.
The input fixtures collect exact bytes inside a real Windows PTY. They cover
configured keys, local mouse actions, side-button releases and horizontal-wheel
SGR reports, including configured bypass. The wheel cases check half-row
accumulation, discrete notches and multipliers at actual font sizes 16/24/32,
then exact alternate-screen and SGR bytes. Inspect the fractional captures
separately. They do not certify physical input or settings-dialog visual coverage. Use
`--project <isolated-project>` to verify a separately staged extension build.
The native close fixture checks idle close, Cancel, Detach, reattachment,
background-job confirmation, sibling survival and natural final-window exit.
Use a fresh evidence directory for each run and inspect its dialog capture.
Use the environment and ConPTY staging instructions in
[Windows development](../../../../../docs/developers/build-and-run/windows-build.md).
