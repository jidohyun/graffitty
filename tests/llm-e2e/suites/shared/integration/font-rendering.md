For Godot Windows, use `python tests/platform/windows/windows_feature_acceptance.py --suite fonts --project <frozen-project> --evidence <new-directory>` with `GRAFFITTY_TEST_SERVER` set to the frozen owner. It drives the actual Fonts dialog and a private PowerShell ConPTY, records exact shaped/Unicode clipboard text, checks real console dimensions and executes a command in the original shell after rejecting and correcting a font. Review paired glyph captures separately from state assertions.

# Fonts and terminal cells

Use a fresh offscreen frontend. Disable typing effects so paired
captures differ only in the selected font settings. Retain the executable hash,
JSONL trace, screenshots and actual copied text.

## Observe fonts and ligatures

1. Print `a != b -> c === d` in the real terminal, followed by a separate line
   containing Greek, Korean and a combining accent. Record the pane PID and grid.
2. Select the bundled JetBrains Mono file with ligatures disabled; capture.
   Enable ligatures and capture at the same camera position and terminal state.
3. Inspect the operators: glyph substitutions must be visibly different, while
   following characters remain on their original cells. Unchanged settings
   metadata alone cannot establish that shaping works.
4. Select an installed monospace family, such as Menlo on macOS. Inspect the
   changed glyph style, fallback Unicode and unchanged terminal layout.

## Select and recover

1. Drag a selection across the shaped operator line. Copy must return the exact
   original characters, not substituted Unicode symbols or shortened content.
2. Change the pane font size; compare the live PTY's `stty size` to the rendered
   cell grid. Header position, cursor and selection must remain aligned.
3. Choose a missing font file. Require an explicit error while retaining the
   current working font and the same live shell. Correct the setting and type
   another command successfully.
4. Record actual rendered observations separately from automated test results.
   Do not claim full bidirectional-script shaping or physical Retina quality
   from these limited, offscreen checks.
