# Hold a window over another tab to preview it, then drop inside to move it

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
4. Move the BRAVO window by its header so both windows are visible. Note
   BRAVO's position.

## Cancel a preview

1. Press on the `BRAVO` handle and drag it onto the middle of CHARLIE's tab.
2. Hold still. Expected: CHARLIE gets an accent outline and a bar that fills
   over about half a second. Then CHARLIE's content is shown.
3. Press Escape, then release.
4. Expected: ALPHA's tab is selected again with both windows, and BRAVO is back
   at the noted position.

## Hover another tab

1. Drag the `BRAVO` handle onto the middle of CHARLIE's tab again.
2. Expected: a placeholder tab titled BRAVO appears in the bar; CHARLIE itself
   does not slide away from the pointer.
3. Hold still until CHARLIE's content is shown. BRAVO's window disappears with
   its tab, but keep the button pressed: the drag continues.

## Drop the window inside

1. Move down into CHARLIE's content, to the lower right quarter.
2. Expected: an outline the size of the BRAVO window, labelled `Move here`,
   follows the pointer at the point where the header was grabbed.
3. Release.

## Verify the moved window

1. CHARLIE's tab shows two windows, CHARLIE and BRAVO. BRAVO sits where the
   outline was, is in front and has keyboard focus.
2. ALPHA's tab contains only ALPHA.
3. Type `echo $$` in BRAVO without clicking first; the PID matches BRAVO's
   original.
4. Report PASS, FAIL or BLOCKED with screenshots of the hover outline, the
   preview, the `Move here` outline and the result.
