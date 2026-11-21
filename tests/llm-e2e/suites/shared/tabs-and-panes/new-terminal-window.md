# Pane split icons open another terminal window in the tab

## Open a second terminal window

1. Launch from the repository root:

   ```sh
   mise run dev -- --shell=/bin/sh
   ```

2. Run `gft pane rename ALPHA` and `echo $$`; note the PID.
3. With default tiling enabled, click **Split right** in ALPHA's title bar.
4. Expected: a new terminal window opens in the same tab, tiled directly to
   the right of ALPHA, so both title bars show. No chromium opens.
5. Expected: the new window has the keyboard. Type `echo $$`: it prints a PID
   different from ALPHA's, and nothing appears in ALPHA.
6. Expected: the automatic tab follows the new focused pane's directory/title.

## Open a third, then close one

1. While the new window has focus, click **Split right** in ALPHA's title bar again. The split must target ALPHA, not the focused pane.
2. Expected: a third terminal window opens to the right of ALPHA, and
   has the keyboard; all three title bars show.
3. Close the third window with **⋯ > Close…**, confirming if prompted.
4. Expected: ALPHA and the second window remain as they were, with their
   shells. The **Chromium** icon still opens a chromium for its terminal.
5. Report PASS, FAIL or BLOCKED with a screenshot after each step.
