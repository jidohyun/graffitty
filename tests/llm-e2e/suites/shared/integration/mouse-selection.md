For Godot on Windows, run `python tests/platform/windows/windows_private_replay.py --replay tests/llm-e2e/suites/godot/integration/replays/mouse-selection.gd --evidence <new-directory>` against the frozen project. It uses a private raw PTY and the real projected pointer path on a private Windows desktop. Do not inject desktop input or access the human's clipboard.

Inspect every capture and `results.json`. The line selection should cover the complete `alpha-beta gamma` row without highlighting the title. The rectangle should cover precisely `EFGH` and `QRST` in adjacent rows. Exact copied strings must agree with these visible spans; a nonempty selection alone is not sufficient.

Check the raw PTY assertions: ordinary and Shift clicks must have exact SGR press/release bytes, while the configured Ctrl bypass must produce no mouse bytes. Primary selection and the normal clipboard retain different text until explicitly changed. Ignore and unbind must not paste accidentally.

Inspect the actual Selection preferences popup for readable, contained controls. After a font resize replaces the streamed VT during a held drag, the old highlight must clear and a new double click must work with the same shell PID. Preserve any failure and record inspected PNG paths in a separate visual review; JSON state cannot establish visual correctness.
