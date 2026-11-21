# Neovim copy-mode regression corpus

`neovim.json` is tracked in DVC, not Git. Fetch it with
`dvc pull crates/terminal-core/tests/copy-mode/neovim.json.dvc`, or
regenerate it with `mise run copy-mode:record`, which runs `record.py` under
the Neovim version pinned in that task and records the version in the file.
`cargo test -p graffitty-terminal-core` then replays it without Neovim or
Python; without the file, `recorded_neovim_parity` prints a skip message and
passes. After regenerating, `dvc add` the file and upload it.

The 169,151 cases include 165,818 exhaustive combinations over five buffers,
386 targeted cases (including Unicode, combining marks, Vim regex, empty rows,
counts and repeated selections), and 2,947 random sequences. Cases compare
copied text for yanks and cursor positions for motion/search commands. Outcomes,
commands and buffers are shared in the JSON to keep the recorded data small.

The original random harness also produced 31 sequences containing unfinished
numeric prefixes such as `20` as a standalone command. Those were excluded:
Neovim's `feedkeys(..., 'x')` drains pending input between commands, while the
copy-mode engine waits for the next key. Another 22 cases used `G` or `M` over
trailing empty terminal rows, where the documented terminal behavior differs.
Exclusions are based on the inputs, not whether an engine result passes.

The reference uses `--clean` defaults, including `nostartofline` and
case-sensitive searches. It removes Matchit's `%` mappings to test the built-in
bracket motion, expands `<lt>` correctly, and converts Neovim byte columns to
terminal cell columns. Clipboard normalization removes exactly one newline
from linewise registers and trims row-end spaces; it preserves selected blank
rows. An empty normalized register is compared as no text.

Regenerate and replay:

```sh
mise run copy-mode:record
cargo test -p graffitty-terminal-core recorded_neovim_parity -- --nocapture
```

`exhaustive.py` generates the exhaustive input; `targeted.jsonl` and
`random.jsonl` freeze the remaining input. `reference.lua` only reads synthetic
buffers and the unnamed register; it does not use the system clipboard.
Window-size-dependent scrolling, plugin surround behavior, and advanced Vim
regex atoms are outside this differential corpus. Existing engine tests still
cover terminal wrapping, rendering coordinates, flash and surround behavior.
