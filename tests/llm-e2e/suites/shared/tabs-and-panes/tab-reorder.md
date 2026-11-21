# Dragging between tabs reorders them

## Prepare labelled tabs

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=3
   ```

2. Label the tabs from left to right. In the first run
   `printf '\033]0;ALPHA\007'; clear; echo ALPHA $$`, in the second the same
   with `BRAVO`, in the third with `CHARLIE`.
3. Record each printed shell PID.
4. Expected: the bar reads `1: ALPHA`, `2: BRAVO`, `3: CHARLIE`, one window.

## Drag a tab along the bar

1. Select ALPHA. Press on its tab and, without releasing, move right along the
   bar at an even pace, without pausing on any tab.
2. Watch while moving: the lifted tab stays under the pointer with the same
   colour and transparency. The opening between its sliding neighbours shows
   where it will land, without a filled placeholder or underline. BRAVO and
   then CHARLIE slide left once the pointer passes the outer quarter of each.
3. Release over the right quarter of CHARLIE's original position.
4. Press CHARLIE and drag it left of every tab, then release.

## Verify the new order

1. After the first drop the order was BRAVO, CHARLIE, ALPHA with ALPHA still
   selected. After the second it is CHARLIE, BRAVO, ALPHA.
2. Select each tab and run `echo $$`. Every PID matches the one recorded.
3. Only one application window exists and no tab was merged or lost.
4. Report PASS, FAIL or BLOCKED with screenshots of the bar after each drop.
