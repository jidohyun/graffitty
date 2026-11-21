# Dragging one of several tabs out, or into its own content, makes another window

This case starts each detach with multiple tabs in the source window. Dragging
its only tab instead moves the existing window and can still merge into another
window; see [single-tab window drag](single-tab-window-drag.md).

## Prepare labelled tabs

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=3
   ```

2. Label the tabs from left to right. In the first run
   `printf '\033]0;ALPHA\007'; clear; echo ALPHA $$`, in the second the same
   with `BRAVO`, in the third with `CHARLIE`. Record each printed PID.
3. Leave empty desktop space beside the application window.

## Drop a tab onto its own content

1. Press on BRAVO's tab. BRAVO's content is shown.
2. Without releasing, move straight down into the middle of the content,
   well below the tab bar.
3. Expected while moving: the tab leaves the bar and the neighbours close the
   gap. A full window with the normal tab strip and native window controls
   (traffic lights on macOS) follows the pointer. There is no blue
   "Join" overlay, because this is the tab's own content.
   BRAVO is visibly selected in the preview: its curved tab background joins
   the live world below, just as it does after dropping the window.
4. Release inside the content.
5. Expected: that same desktop window stays at the pointer, without a jump or
   replacement frame, containing only BRAVO.
   It owns a new numbered live server session. The original window and its
   session keep ALPHA and CHARLIE.

## Drag a tab out of the window

1. In the original window, press on CHARLIE's tab.
2. Move the pointer off the application window onto empty desktop space. The
   complete window follows, including its native controls.
   CHARLIE remains visibly selected throughout the drag and after release.
3. Release on the desktop.
4. Expected: the dragged window stays there with only CHARLIE. The original
   keeps ALPHA only. CHARLIE's window gets another numbered live session.

## Verify the windows

1. Three application windows exist: ALPHA, BRAVO and CHARLIE, one tab each.
2. In each window run `echo $$`. The PIDs match the ones recorded.
3. Type `echo typed-here` in each window. Output appears only in that window.
4. Report PASS, FAIL or BLOCKED with a screenshot of all three windows.
5. Verify all three session names in `gft session list --json`. Detach and explicitly
   attach to each with `gft session attach -t NAME`: the same tab, shell PID and
   output must return in the appropriate window without creating another shell.
