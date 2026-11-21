# Crowded tab labels and continuous add/remove animations

With enough room for a number and close button, the active tab shows both.
Hovering an inactive tab shows its close button beside its number. With room
only for the number, every tab keeps its number, including tabs with empty or
one-character titles. Only the active tab replaces its number with close when
the pointer is directly over the number. Leaving restores the number. Clicking
an inactive number selects that tab without closing it.

With ample room, add a second tab using the plus button. The first tab must
keep its bounds; the new tab opens to its right, never over its close button.
The new tab and plus hit target stay separated throughout the animation,
including when another tab is added before the preceding insertion finishes.

Add a tab to a crowded strip using the plus button. The new tab starts narrow
outside the preceding tab's edge and grows while the other tabs shrink and move
left. Close the last tab: it shrinks away outside the preceding tab while
surviving tabs grow and their right edges move right. With ample room, surviving
tabs stay fixed. The closing label retains its normal content insets; it must
not jump left or slide over a neighbour's close button. The viewport must retain
the closing view until it finishes shrinking, and the plus hit target stays
outside it. Verify trailing, middle, adjacent simultaneous and rapid repeated
closes, and interrupt insertion with closure and closure with insertion.
Both transitions must have intermediate rendered bounds, without snapping widths
or restarting on ordinary owner updates.
Adding another tab during an animation continues from the current bounds.
The plus button follows the changing trailing edge smoothly when tabs have
already reached their maximum width.

The reference is Chromium's
[TabContainer](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/tabs/tab_container.cc),
[BoundsAnimator](https://chromium.googlesource.com/chromium/src/+/main/ui/views/animation/bounds_animator.h),
and [Tween](https://chromium.googlesource.com/chromium/src/+/main/ui/gfx/animation/tween.cc):
200 ms quadratic ease-out over complete bounds, narrow insertion at the
preceding edge, and deletion after the closing animation. Chromium subtracts
its decorative tab overlap in `StartInsertTabAnimation` and
`GetTargetBoundsForClosingTab`; Graffitty uses a positive 3 px gap instead, so
that subtraction must not be copied onto its content bounds. Closing content
collapses to zero at the preceding edge, with its label insets preserved inside
a clipping view. `GetMidAnimationTrailingX` keeps Chromium's closing tabs inside
the viewport; Graffitty likewise retains the animated extent instead of clipping
immediately to the final tab count. Chromium's [`Tab::UpdateIconVisibility`](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/tabs/tab.cc)
also hides the close control below the minimum tab width; a collapsed insertion
must not expose a close hit target outside its own tab.

Repeated mouse closes of non-trailing tabs hold widths so the next close button
stays under the pointer. Moving up to 40 logical pixels below or 60 pixels right
of the strip keeps that mode. Leaving further waits 300 ms before animated
expansion; returning before the deadline cancels it. An outside press releases
it immediately. Touch closes wait two seconds (postponed during a drag).
Trailing closes permit immediate expansion. Keyboard closes do not enter
closing mode. Inserting a tab releases the constraint. The first tab and hidden
initial layout do not animate.

Record per-frame bounds during actual plus/close clicks against a private
session server. Capture both compact label widths and the selected hover state.
