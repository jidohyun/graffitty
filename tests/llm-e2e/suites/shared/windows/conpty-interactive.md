# ConPTY 1.25 terminal behavior

Windows-only supplement to the shared suites. Use isolated D: state and evidence; do not alter personal profiles. Report each shell separately.

## Verify the loaded ConPTY runtime

Start the D: dev server with checksum-pinned conpty.dll and OpenConsole.exe beside dist/bin/gft.exe. Record file versions and the actual loaded module, not merely file existence. Run in the interactive desktop. Use separate PowerShell 5.1 and 7 panes and retain their version output.

## Exercise terminal queries and mouse modes

Run the shared terminal color/query and mouse/scroll procedures in both shells. Verify a real application receives OSC 10/11 replies, enables mouse reporting, and scrolls with the wheel. Run gft terminal icat with a real image and review its decoded pixels. Retain terminal query traces and continuous video; a Python console PTY using the inbox runtime is not equivalent evidence.

The Godot replay provides supporting OSC 10/11 and SGR wheel traces in
`powershell.exe-conpty.json` and `pwsh.exe-conpty.json` under its isolated state
directory. These use the production server's PTY and synthetic Godot wheel input;
they do not certify physical wheel input, image pixels or runtime module identity.

For guided physical input, run `tests/platform/windows/windows_manual_input.ps1 -Stage Start
-Evidence <fresh-directory>` inside each Godot PowerShell pane at 150% Windows
display scaling. Follow its Interrupt, Copy, Wheel and Review stages, reusing
the same evidence directory and pane. Retain a continuous recording beside
`physical-input.json` and `physical-wheel.json`. The helper checks the original
shell PID, exact copied marker and real terminal wheel bytes; physical input
and visual review require the operator's explicit attestation. This covers only
that manual subset, not the remaining procedures below.

## Exercise native node input

Launch real Manual Prompt and Scheduled Trigger nodes in Graffitty panes. Verify multiline entry, Ctrl+Enter submit/arm, disarm on editing, delivery receipts, and unchanged shell identity after closing the nodes. Test the production server, not a graph-only fixture lacking graph.read or PTYs.
