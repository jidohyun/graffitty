# Dragging the only tab moves its window and still allows merging

When a desktop application window has exactly one tab, dragging that tab must
behave like dragging the window by its title bar. The original native window
moves with its contents; the tab must not detach into a new window or leave an
empty source window. It must still be possible to drag into another application
window and merge there. This rule depends on the number of tabs in the source
window, not the number of panes in its tab or tabs in other windows.

Every newly created desktop window owns a separate numbered live server session.
Moving a sole-tab window preserves that session. Detaching one of several tabs
into a new window creates a new numbered session containing the moved live tab;
dropping into another window transfers it to that window's session. Neither
operation restarts the shells. An emptied source session is removed only after
the transfer succeeds, while the destination's live panes keep the server alive.

Run independently for every required frontend using isolated local state and
real native desktop windows. Record continuous drags and native window
identities/counts before, during, and after each gesture. A final screenshot or
unchanged window count cannot prove the original window was not replaced.
Embedded replay windows and headless state checks are supporting evidence only.

## Prepare two windows and record their identities

1. Open two local application windows, A and B, using the frontend's supported
   controls. Use only test-owned sessions and shells on an isolated server.
   Leave enough empty desktop space to move A without overlapping B.
2. A has exactly one tab, ALPHA. B has two tabs, BRAVO and CHARLIE. Label each
   shell with an OSC title, for example
   `printf '\033]0;ALPHA\007'; clear; echo ALPHA $$`, and record its PID and
   terminal ID. Record window IDs and rectangles, tab IDs and ownership, pane
   layouts, selected tabs, and camera pan/zoom.
   Record `gft session list --json` and each window's server session name. A and B
   must be distinct sessions, including when both use the same server process.
3. Move A by its ordinary title-bar drag area and observe the pointer's grab
   offset and whole-window motion. Return it to the starting position. Use
   this as the reference behavior for dragging ALPHA's tab.

## Move the original window by its only tab

1. Click and release ALPHA's tab, then repeat with pointer movement below the
   drag threshold. Neither gesture detaches the tab or creates a window.
2. Press ALPHA's tab and drag beyond the threshold horizontally, vertically,
   and diagonally into empty desktop space. Pause while holding, then release.
   Repeat across the original window boundary and over coordinates that were
   inside its content when the drag began.
3. Throughout each gesture, A itself follows the pointer like the title-bar
   reference, preserving the grab offset. Its tab bar and panes move together.
   There is no detached-tab window, translucent replacement-window drag copy,
   empty source shell, or source-window close/reopen. A retains its native
   identity and size; exactly the original two application windows exist.
4. ALPHA stays in A. Its layout, terminal IDs, shell PIDs, retained text, and
   camera view remain unchanged. B does not move or change tabs. Type a new
   marker into each shell and verify output reaches only the intended pane.
   The session inventory and A's session name remain unchanged throughout.
5. Add a second pane inside ALPHA, leaving A with one tab, and repeat. Both
   panes move with the original window and keep their identities and layout.
   A sole tab with multiple panes must not enter the multi-tab detach path.

## Leave or cancel a merge preview

1. Drag A by ALPHA's tab onto B's CHARLIE tab. Hold until the target preview
   appears, then move into the previewed content. Require a visible merge
   indication, consistent with [tab hover merge](tab-hover-merge.md).
   Moving the whole source window must not obscure or disable the drop target.
2. Move away onto empty desktop space before releasing. The merge indication
   disappears; release moves the same A window there. Both windows retain
   their original tabs and panes, with no transfer or extra window.
3. Repeat the preview and press Escape before releasing the pointer. The
   merge is canceled: tabs and panes retain their original owners, B returns
   to its pre-preview selection/view, and all preview graphics disappear.
   A keeps its native identity; its position follows the ordinary window-drag
   cancellation behavior. Releasing afterward must not commit a stale drop.

## Merge into another window

Use fresh copies of the two-window fixture for each drop route. Repeat with
one pane and multiple panes inside A's only tab.

1. Drag ALPHA to an insertion position in B's tab bar and release. B receives
   ALPHA as a tab exactly once at the indicated position. BRAVO and CHARLIE
   retain their relative order. ALPHA keeps its tab ID and all live panes.
2. In a fresh fixture, drag ALPHA over CHARLIE, wait for its content preview,
   move into the indicated Join area, and release. All ALPHA panes merge into
   CHARLIE's content exactly once, alongside CHARLIE's existing panes. BRAVO
   remains unchanged. No duplicate standalone ALPHA tab remains.
3. For both routes, A moves as the original window until the merge commits.
   Only after successful transfer does its now-empty presentation window close.
   B retains its native identity; two application windows become one without
   a third or replacement window appearing at any point.
4. Transferred panes are moved, not closed and recreated. All source and target
   terminal IDs, shell PIDs, and output survive. The server remains running
   with these live panes; closing the emptied source presentation must not
   trigger last-pane/session shutdown. Type distinct markers into every pane
   and verify correct routing and usable focus. No unexpected dialog appears.
5. Check `gft session list --json`: A's empty session is gone and B's session owns
   the transferred panes. Detach and use `gft session attach -t B_SESSION` to
   verify the merged tabs, shell PIDs, and retained output from the server.

## Check the transition between one and multiple tabs

1. On a fresh fixture, give A two tabs. Drag one to empty desktop space:
   [tab new window](tab-new-window.md) still applies, so the dragged tab gets
   a new window while A retains the other tab and its native identity.
   The new window must have a distinct numbered session in `gft session list --json`
   and support explicit attachment to that number with the same live shells.
   The ordinary New Window command must also allocate a new numbered session.
2. Immediately drag A's remaining tab. It now moves A itself with no further
   detachment. Drag the detached window's sole tab as well: that window moves
   itself. The rule must be recalculated after the tab count changes.
3. Merge either sole-tab window into another and repeat a normal multi-tab
   reorder/detach there. Moving a sole-tab window must not disable subsequent
   tab dragging or merging.
4. Report PASS, FAIL, or BLOCKED with the frontend/build identity, continuous
   recording, screenshots during movement and merge preview, window identity
   and ownership observations, and before/after shell evidence. Missing native
   drag or merge evidence is BLOCKED; a replacement window or lost shell is
   FAIL. Do not substitute another frontend's result or fixture setup for the
   actual drag gestures.

`python3 tests/godot/tab_window_e2e.py --scenario window --gpu --evidence NEW_DIRECTORY`
exercises production startup, same-window motion, numbered session detachment,
cross-session tab-bar/content drops, Escape cancellation, shell identities, and
New Window under the native background-render guard. It also checks live shell
input/output after each transfer and final rendered panes after merging the
original primary window into a later window. Physical pointer behavior,
native title-bar parity, and the complete recorded procedure still need review.
