# Hold a tab over another tab to preview it, then drop inside to merge

This case exercises merging within a window containing several tabs. Merging
the only tab of another desktop window must also remain possible while dragging
that original window; see [single-tab window drag](single-tab-window-drag.md).

## Prepare labelled tabs

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=3
   ```

2. Label the tabs from left to right. In the first run
   `printf '\033]0;ALPHA\007'; clear; echo ALPHA $$`, in the second the same
   with `BRAVO`, in the third with `CHARLIE`. Record each printed PID.
3. Select ALPHA.

## Cancel a preview

1. Press on ALPHA's tab and drag it onto the middle of CHARLIE's tab.
2. Hold still. Expected: CHARLIE does not slide away. It gets an accent
   outline and a bar along its bottom edge fills over about half a second.
3. Once the bar fills, CHARLIE's content replaces ALPHA's. ALPHA's tab is
   still lifted under the pointer.
4. Press Escape, then release.
5. Expected: ALPHA is selected again, all three tabs remain in their original
   order and nothing merged.

## Hover to preview

1. Press on ALPHA's tab again and drag it onto the middle of CHARLIE's tab.
2. Move away from CHARLIE before the bar fills. Expected: the outline
   disappears and CHARLIE is not shown.
3. Return to the middle of CHARLIE and hold still until CHARLIE's content is
   shown. Keep the button pressed.

## Drop into the previewed content

1. Move down into CHARLIE's content.
2. Expected: the lifted tab leaves the bar and a blue overlay covers the
   content, labelled `Join "CHARLIE"`.
3. Move back onto the tab bar without releasing. Expected: the content's
   split/Join preview disappears immediately; only tab insertion is shown.
4. Move down into the content again. Its merge preview returns.
5. Release inside the content.

## Verify the merged tab

1. Two tabs remain: BRAVO, and the merged tab titled ALPHA because ALPHA has focus.
2. CHARLIE's tab shows two separate windows, ALPHA and CHARLIE. Each moves by
   its header without affecting the other.
3. In the ALPHA window run `echo $$`; the PID matches ALPHA's original.
4. Report PASS, FAIL or BLOCKED with screenshots of the hover outline, the
   preview, the Join overlay and the final tab.
