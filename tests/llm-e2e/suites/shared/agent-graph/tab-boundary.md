# Connected graphs stay inside a tab

## Prepare a connected group

1. Launch an isolated workspace with two tabs. In the first, create four panes
   named ALPHA, BRAVO, CHARLIE, and UNRELATED; name the second tab TARGET.
2. Register test nodes with an `out` output and an `in` input. Connect
   ALPHA → BRAVO and CHARLIE → BRAVO; pause the second connection. Leave
   UNRELATED and TARGET disconnected. Record every pane's `%N` and shell PID.
3. Arrange the source panes with visibly different positions and sizes. Zoom out
   until all three connected panes and their wires are visible. Record their
   rectangles before pressing any header. Enable tiling and physics in TARGET.

## Reject cross-tab connections

1. Send `graph.connect` requests from ALPHA to TARGET and TARGET to ALPHA,
   including a paused connection request. Use the real authenticated API/CLI.
2. Every request must fail with an explanation that connections stay within one
   tab. Compare the graph before and after: no edge or permission may be added.

## Preview and move the connected group

1. Press BRAVO's header, move within its source canvas, then hover TARGET's tab
   until it opens. Continue into TARGET's canvas without releasing.
2. The preview must show ALPHA, BRAVO, CHARLIE and both connecting wires,
   including the paused wire. UNRELATED must not appear in the carried preview.
3. Compare the preview to the rectangles recorded before pressing the header:
   all three panes must have the same translation, with unchanged sizes.
   TARGET's tiling must not split or rearrange the group.
4. Capture the preview, release, and wait for physics to settle. BRAVO, the
   dragged anchor, must land where previewed. Other floating group members
   retain their sizes and yield independently to reduce overlap with the
   destination tile, subject to keeping their drag handles reachable. Both connections remain intact. UNRELATED
   stays in the original tab, and TARGET stays in its destination tab.
5. Check every original PID and `%N`. No shell may restart. A new connection
   from the moved group back to UNRELATED must now be rejected.

## Move to a new tab and cancel a move

1. Record the group's current rectangles. Drag BRAVO's header onto empty space
   at the end of the tab bar. The placeholder must identify a connected group.
2. Release. One new tab must contain all three connected panes, at their
   pre-drag positions and sizes. TARGET and UNRELATED must stay behind.
3. Start another header drag, hover the original source tab, and enter its
   canvas. Capture the group preview, then press Escape before releasing.
4. Membership, connections, positions, and PIDs must remain unchanged.
5. Report PASS, FAIL, or BLOCKED with before/preview/after/cancellation evidence.
   Inspect the actual rendered panes and wires; protocol checks alone do not
   certify the visual preview. Other frontends require their own execution.
