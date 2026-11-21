# Dragging a window onto the tab bar makes a new tab

## Prepare a tab with two windows

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=3
   ```

2. Label the tabs from left to right. In the first run
   `printf '\033]0;ALPHA\007'; clear; echo ALPHA $$`, in the second the same
   with `BRAVO`, in the third with `CHARLIE`. Record each printed PID.
3. Merge BRAVO into ALPHA: drag BRAVO's tab onto the middle of ALPHA's tab,
   hold until ALPHA's content shows, move down into it and release. If that
   fails, report BLOCKED and refer to `tab-hover-merge`.
4. Expected: tabs `BRAVO` (focused pane in the two-pane tab) and `CHARLIE`. Move the BRAVO window by
   its header so both windows are visible, and note BRAVO's position and size.

## Drag a window onto the tab bar

1. Press on the `BRAVO` handle at the left of BRAVO's window header.
2. Move within the content first. Expected: the window follows the pointer.
3. Move up onto the tab bar, to empty space right of the last tab.
4. Expected: the window returns to where it started and stays there. A
   placeholder tab titled BRAVO appears at the end of the bar.
5. Move left over the gap between ALPHA and CHARLIE. Expected: the placeholder
   moves there and CHARLIE slides right. It never jumps back and forth while
   the pointer is still.
6. Return to the empty space right of the last tab and release.

## Verify the new tab

1. The bar reads ALPHA, CHARLIE, BRAVO, and BRAVO is selected.
2. BRAVO's tab contains only the BRAVO window, at the same position and size
   noted before.
3. ALPHA's tab contains only the ALPHA window, so its automatic title is ALPHA.
4. In BRAVO run `echo $$`; the PID matches BRAVO's original.
5. Report PASS, FAIL or BLOCKED with screenshots of the placeholder and the
   result.

## Change from a split preview to a tab

1. Enable tiling in ALPHA's tab, then select BRAVO.
2. Drag BRAVO's pane header over ALPHA's tab and hold until ALPHA opens.
3. Move into ALPHA's content. Expected: a split placement preview appears.
4. Move back to empty space on the tab bar. Expected: the split preview clears
   immediately and only the incoming tab placeholder remains.
5. Release. Three separate tabs remain, with the same shell PIDs; ALPHA was
   not split by a drop onto the tab bar.
