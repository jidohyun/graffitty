For the Godot Windows adapter, set `GRAFFITTY_TEST_SERVER` to the built native
CLI and run `python tests/platform/windows/windows_restore_e2e.py --godot <Godot-exe> --shell
powershell.exe --evidence <new-directory>`. Repeat with `--shell pwsh.exe` and a
fresh directory. This uses real native windows, private owners and history;
review all `before/window-*.png` and `after/window-*.png` separately and retain
the report's binary hashes. `geometry.json` records the rendered usable areas.

Save two windows containing three real shells, different font sizes, pinned titles, a weighted split, and a working directory containing spaces and Unicode. Inspect the actual version-1 saved document. Its paths must remain in the private directory with private permissions. The native CLI's ordinary `session.capture` must still return terminal text; explicit session Save must obtain presentation metadata through the scoped broker. An invalid caller capability must not write history.

Stop the original isolated frontend and owner, and prove its original PTYs have exited. Restore into a new frontend that already contains an independent live shell. Require new restored PIDs, preservation of that existing shell, matching pane rectangles/fonts/grids/pinned titles, and two remapped real window adapters with their original camera views. Readiness receipts may report success only after those adapters exist. Type into every restored shell and verify its saved working directory and exact parent shell PID from a private child-written JSON file; terminal line wrapping must not affect that assertion.

Inspect `before/before-restore.png` and `after/restored-window-*.png`. Confirm readable titles, terminal contents, layout boundaries and the authored world background. Record a separate visual-review.json with the specific files inspected and frozen hashes. This test proves newly created shell and layout restoration; it does not claim continuation of arbitrary running programs, reconstructed PTY scrollback, chromium restoration, or native operating-system window placement.
