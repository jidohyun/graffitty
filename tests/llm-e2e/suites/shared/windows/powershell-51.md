# Windows PowerShell 5.1

Windows-only supplement to the shared suites. Use isolated D: state and evidence; do not alter personal profiles. Report each shell separately.

## Start an isolated Windows PowerShell 5.1 pane

Use a private server config with `[terminal] shell = ["powershell.exe", "-NoLogo"]` and `shell_integration = true`. Start the current dev Godot client in the interactive desktop. Print `$PSVersionTable.PSVersion` and assert major 5, minor 1. Record the actual executable path, server PID and loaded ConPTY DLL path. The prompt must stay alive. Repeat with shell integration disabled: the interactive shell must still remain usable.

## Exercise Unicode cwd and filetree

Create a private directory on D: named `한글 space % #`. Use `Set-Location -LiteralPath` to enter it. Print `(Get-Location).Path` and `한글 Ω 😀`; inspect rendered text and the server-reported cwd. Open the filetree through its header button, verify its root, change directory and verify following. Rename a text file in the Fyler buffer and open it in real Neovim. No warning dialog is allowed.

## Exercise input and interrupts

Type and edit a multiline PowerShell command, run it once and verify exact output. Run a long foreground loop, press physical Ctrl+C, and confirm it stops while the same shell PID survives. Verify Ctrl+Shift+C copy with selection separately from Ctrl+C interrupt without selection. Run the Windows hook test for this shell and retain its verbose output.

## Review the native recording

Record startup, typing, cwd following and interruption continuously. Inspect clear frames at 150% Windows scaling. Record PASS only with assertions plus visual review; synthetic Unicode text input does not certify Korean IME composition.
