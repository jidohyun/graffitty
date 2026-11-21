# Changing the world keeps the tabs and windows

Regression: choosing another world added a tab for every place the world had,
and changing back kept them all.

## Arrange tabs and windows

1. Launch from the repository root:

   ```sh
   mise run dev -- --shell=/bin/sh --tabs=4
   ```

2. Name the tabs ALPHA, BRAVO, CHARLIE and DELTA: in each, run
   `gft pane rename NAME`. In each, also run `echo $$` and note
   the shell's PID.
3. Merge BRAVO into ALPHA: drag BRAVO's tab onto ALPHA's, hold until ALPHA
   opens, move down into its content and release. Move the two windows apart by
   their headers so both show.
4. Rename that tab PAIR: `gft tab rename PAIR` in one of its
   windows. Drag DELTA's tab to the front of the bar.
5. Click PAIR's tab, then inside the BRAVO window so it has the keyboard.
   Take a screenshot.

## Change to Bistro

1. Choose **View > World > Bistro** and wait for the camera to land.
   If the item is missing, report BLOCKED: the Bistro world is not installed.
2. Expected: the tab bar reads DELTA, PAIR, CHARLIE, exactly as before, and
   nothing else: no new tabs. PAIR still holds both windows.
3. Expected: PAIR is still selected, both its windows are where they were, and
   typing goes to BRAVO. In each tab, `echo $$` prints the same PID as before.
4. Click the **+** button to open a new tab.
5. Expected: the camera flies to a part of Bistro none of the other tabs
   stands at, and the new tab's terminal lands there. Selecting the other tabs
   flies to the places they had.
6. Select PAIR and choose **⋯ > Move to New Tab** in BRAVO's title bar.
7. Expected: BRAVO becomes a tab of its own at another new place, and the
   camera flies there.

Godot: tabs exchange content on the wall in view and do not travel between
places. In steps 5 and 7 the new tab must appear on the wall already in view,
with the camera at rest there, and still be given a place of its own.

## Change back to the flat world

1. Choose **View > World > Flat**.
2. Expected: the same tabs as just before, with the new ones last, and the
   same windows, names, shells and focused window. No other new tabs.
3. Report PASS, FAIL or BLOCKED with the screenshots.
