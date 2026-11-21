# Tab flights restore each space's camera view

Launch `mise run dev -- --world=color --shell=/bin/sh --config=tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf`. Keep the window size fixed. This fixture makes typing and idle zoom equal so transient typing effects cannot masquerade as remembered navigation zoom. Record continuous video of switches and capture settled reference screenshots. Report PASS, FAIL, or BLOCKED with evidence; idle screenshots alone cannot prove a correct animation destination.

## Prepare distinct views

Create tabs ALPHA, BETA, and GAMMA. Turn off **View → Floating Pane Physics** in each so collision responses cannot change the reference placements. In each, create two terminals, print unique markers and `echo $$`, and arrange them differently. Use pinch zoom and right-button dragging to set ALPHA to a close view panned right and up, with an off-center terminal prominent in view. Set BETA to a wider view panned left and down. Leave GAMMA at **View → Fit to Main Area**. Do not move panes to simulate camera navigation.

After gestures settle, capture a reference for each tab showing the pane corners, text scale, and main-area border where visible. Record navigation zoom and pan when observable, in addition to screenshots. The three references must be visibly distinct in both scale and framing. Wait for each view to settle before leaving it.

## Restore the destination during the flight

Switch ALPHA → BETA → GAMMA → ALPHA, then reverse the sequence. For every switch, the animation must finish at the destination tab's own last settled zoom and pan. It must not inherit the source tab's framing, fit all panes, or reset to Main Area. Once settled, pane corners and text scale must match that destination's reference (allow at most two screen pixels of rasterization rounding).

Inspect the recording through the landing and for at least one second afterward. The flight must approach the remembered destination directly and continuously, with no intermediate landing at a default view followed by a second pan/zoom, snap, or corrective jump. Tabs must remain interactive afterward: click a visible terminal and type a marker without an unexpected camera reset.

## Update one remembered view

In BETA, change both zoom and horizontal/vertical pan to a new, clearly different view. Wait for gestures to settle and capture a new reference. Visit ALPHA and GAMMA: their original references must still match. Return to BETA: only its new reference must match, including the flight's destination. Repeat the round trip twice to detect accumulated drift or a saved view being overwritten on tab entry.

## Interrupt switches and reset one tab

Start ALPHA → BETA and click GAMMA before the flight finishes. After landing, GAMMA must match its saved Main Area view. Return to ALPHA and BETA: both must retain their last settled references; an intermediate animation frame must not overwrite either saved view. Repeat with BETA → ALPHA interrupted by BETA and verify BETA returns to its own latest view without a jump.

In BETA, choose **View → Fit to Main Area**, let it settle, and capture that reset view. Switch away and return: BETA must now remember Main Area, while ALPHA keeps its custom zoom and pan. Verify pane placements, tab membership, and original shell PIDs are unchanged by all navigation and switches.
