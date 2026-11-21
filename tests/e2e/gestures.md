# Trackpad, pinch, pan, and latency acceptance

## GE-01 — Natural trackpad default and saved mode

Fresh-install or clear only a disposable preference fixture. Connect to a desktop.
One-finger movement must move the pointer relatively, not touch the corresponding
absolute screen point. Reconnect/restart and verify persistence. Check an explicitly
saved alternate mode is preserved; when the user requests Trackpad on an existing
device, change and verify that saved mode.

Test every mode in the floating mode chooser. Its icon must reflect the active mode,
and its labels must explain the distinction between direct touch and trackpad modes.

## GE-02 — Always-on pinch with scroll discrimination

Without pressing any zoom button:

1. Parallel two-finger movement scrolls the remote content without accidental zoom.
2. Spreading/converging fingers zooms locally around the fingers.
3. Moving their midpoint pans while zooming.
4. Ambiguous/tiny initial motion does not leak a remote click or begin both gestures.

Use Graffitty's gesture ownership as the reference: approximately 120 ms initial
intent grace, shortened to 50 ms once motion establishes intent. Preserve remote
scroll behavior and do not emit buffered events twice. Test slow pinches, quick
scrolls, diagonal movement, two-finger taps, and cancellation.

On a Windows Precision Touchpad, put the cursor over an off-center workspace
point. A stationary pinch should keep that point under the cursor. During the
same contact, slide diagonally, hold the finger spacing steady, then reverse
the pinch. The workspace should follow the slide continuously. Lift both fingers
and start a fresh parallel scroll over a terminal to check scroll ownership.

## GE-03 — Continuous pinch → one-finger pan → pinch

Acquire local navigation with two fingers. Lift either one, pan with the survivor,
add another finger, and continue zooming/panning. Repeat with pointer index/order
changes. Navigation ownership lasts until all contacts lift. Re-adding a finger must
not jump, reset the zoom, or start a remote drag. After all fingers lift, a fresh
parallel two-finger gesture can scroll normally again.

## GE-04 — Free pan and no fixed letterbox clipping

Use a remote monitor with a different aspect ratio from the device. Zoom and pan in
both axes at small and large scales:

- Image proportions remain correct, but zoom can expand into former black bars.
- The original letterbox rectangle must not clip the enlarged image.
- Manual pan is not constrained to keep the entire image inside/covering the viewport.
- Do not recenter a smaller axis or snap back when a finger lifts.
- Keep navigation smooth across surface/rotation changes and keyboard transitions.
- In Graffitty, repeat with left/right/both sidebar docks and after resizing them.
  Zoom follows the visible main-content rectangle, including its horizontal
  offset. Pinch anchors and inverse hit testing must agree with the rendered
  projection; the terminal cursor must not be considered visible behind a dock.
- Repeat with a floating (undocked) panel open, both right after tapping inside
  it and with it untouched. Touches on the panel's body or title stay with the
  panel; one- and two-finger pan and pinch elsewhere still navigate the
  workspace. Only modal windows (dialogs, menus) block the whole workspace.
- A pinch may straddle a docked sidebar; see GE-08.
- In Graffitty Flat 2D and Flat 3D, start adaptive typing zoom and interrupt it
  with pan, wheel zoom, or pinch, both from Main and from an overview. Manual
  movement takes over from the displayed frame without a snap. After release,
  terminal output and the typing idle timeout must not move the camera again.
  Fresh typing resumes adaptive framing smoothly from that view. Repeat while
  adaptive zoom is returning to rest and with Android/iOS touch navigation.

RustDesk mobile's free-offset navigation is the reference; earlier bound-clamping
behavior is a regression, not an acceptance requirement.

## GE-05 — Mouse-follow viewport

Zoom so some desktop is offscreen. Move the pointer toward every edge using the
trackpad. The viewport follows sufficiently to keep the pointer visible, with
RustDesk-style directional center crossing when more desktop is available. Check
reverse movement, corners, display edges, and transitions from manual pan. Do not
suddenly undo manual placement or feed viewport translation back into finger deltas.

Distinguish locally controlled cursor tracking from host cursor feedback: independent
movement made on the Mac cannot be claimed to follow unless the protocol reports it.

## GE-06 — Immediate local cursor under latency

Repeat movement, click, double-click, and drag with delay/jitter and a short host
stall. The visible local cursor follows finger movement immediately, independently
of delayed video. Remote cursor movement can catch up later.

- Send/coalesce current absolute position rather than building a stale movement backlog.
- A click/drag must be ordered after its intended position; never drop click edges.
- Account for zoom, pan, letterbox, display switching, and changing stream dimensions.
- Verify the client does not show two competing cursors; validate host cursor-capture
  suppression where supported, and document the limitation where unavailable.
- Verify local/remote alignment when the connection recovers and when switching modes.

A local cursor rendering test is necessary but is **not** an induced-latency E2E pass.
Remote action latency still exists and must not be advertised as removed.

## GE-07 — Graffitty three-finger remote switching

Connect at least two remotes with distinct scratch panes. Three fingers moving
left select the next connected remote; right selects the previous, in connection
order. Restore that remote's last selected tab/pane rather than opening another
terminal. Saved but disconnected remotes are skipped. No wrapping at either end:
show a small resisted displacement and spring back.

The desktop slides horizontally with the fingers and settles smoothly on release.
The workspace root and dock sidebar belong to the same centrally managed sliding
presentation, including the outgoing snapshot; the sidebar must not remain fixed
or cover the outgoing desktop. Floating controls and menus are stationary chrome.
Cancel/settle resets every registered desktop layer, not a list of widget offsets.
A short drag snaps back without changing the settled selection; a deliberate
swipe or flick commits. Reversal, cancellation, a fourth finger, focus loss,
rotation, and disconnect during the gesture must not leave translated content,
a stale screenshot, clicks, held buttons, or momentum in either remote.

Three-finger **vertical** movement continues scrolling; two-finger pinch/pan and
one-finger input retain their existing behavior. Lock the axis after clear intent.
Remaining fingers after a completed/canceled swipe must not click or scroll the
new remote. Popups, controls and keyboard editing keep touch ownership. Verify
with a real PTY/browser event logger, on phone and foldable geometries. Observe
rendered motion and frame pacing on a device; Rust tests alone cannot establish
the animation's feel or absence of device input leakage.

## GE-08 — Graffitty pinch across a docked sidebar

Dock a list panel (Agents or Sessions) and put one finger on its content and
the other on the main area, in either order. The two fingers pinch and pan the
workspace exactly as two fingers on the main area do, anchored under both.

Every contact has one owner while it is down. The sidebar gives up only a
finger that is still resting: one that has not moved past the touch slop and has
been down for less than 400 ms. That finger is canceled in the sidebar, so it
selects no row, presses no button and scrolls nothing, and the sidebar receives
nothing more from it until it lifts. A main-area finger takes a sidebar finger
along only while it is resting too, or already navigating.

Whatever a surface has decided on, it keeps:

- A finger already scrolling the sidebar keeps scrolling it; a second finger on
  the main area starts its own one-finger gesture.
- A finger held on the sidebar past 400 ms stays a long press there.
- A pane drag or one-finger scroll under way is never interrupted by a sidebar
  touch. The drag continues and the sidebar handles the second finger itself.
- Dock titles, resize edges and stack dividers never join a pinch, nor do a
  compact band's drag body, floating buttons, the key bar, scroll bars or a
  floating panel over the sidebar.

Check both finger orders, left and right sidebars, top and bottom bands, a
narrow and a wide sidebar, and both hands' natural landing delay. After every
case, a plain sidebar tap, sidebar scroll, title fold, edge resize and
main-area tap must still work on the first try, with no stuck pressed row or
button. Repeat GE-03 with the surviving finger on the sidebar.

## GE-09 — Graffitty lists and menus glide after a flick

Flick a finger across a touch context menu and across a panel list (Agents,
Sessions, Resource Monitor), floating and docked. The content keeps moving
after the finger lifts and slows to rest with the same momentum model as
one-finger terminal scrolling. A drag that rests before the finger lifts stops
where it is.

- The model is shared by terminals, panels, menus and lists. Release speed and
  the start threshold follow Chromium's touch handling on Android (a quadratic
  least-squares fit over the last 100 ms; 50 to 8000 dips/s; a finger that
  pauses 40 ms between moves or 80 ms before lifting has stopped). The glide
  decelerates as UIScrollView does (velocity × 0.998 per ms, so it travels
  about half a second of the release speed), to match the Apple rubber band. A
  quick flick in the same direction on a glide still faster than 350 dips/s
  adds that glide's launch speed (Chromium's fling booster).
- A touch on gliding content stops it and is not a tap: no row is activated and
  no menu command runs. Holding that finger still becomes a long press, and
  dragging it scrolls, as on resting content.
- A glide that reaches the first or last row overshoots briefly and returns
  (GE-12); it never leaves the list displaced.
- A second finger, a canceled touch (including a finger the sidebar gives up to
  a pinch, GE-08), a mouse wheel, rebuilding the menu and closing it all end the
  glide.
- A mouse drag on a menu does not glide.

Judge the feel on a phone and a foldable; headless tests only establish that a
flick glides, brakes and rests.

Three-finger remote-switch fixtures start all contacts in the usable workspace
region after dock reservations. A narrow phone may place the full-window center
inside a dock; that is not a workspace gesture starting point.

## GE-10 — Graffitty terminal rubber band

With one-finger terminal scrolling (the default), the rows move exactly as far
as the finger, as a Chromium page does, at any font size or zoom. Drag a
terminal with scrollback past its first row and past its live bottom. The content shifts away
from the pulled edge, by about a twentieth of the finger's travel, leaving an
empty band there, while the viewport stays on the same rows. Lifting the finger
lets it settle back with no displacement left. A flick whose glide reaches an
edge overshoots briefly and returns. Three-finger scrolling behaves the same.
The look is the same as on a Mac trackpad, not Android's own stretch.

- A terminal with no scrollback can still be pulled, both up and down.
- An alternate-screen or mouse-reporting application (Vim, less, htop) does not
  stretch; its own scrolling is unchanged.
- A second finger, a canceled touch, a key press and a touch that brakes a
  glide all release the stretch; none leaves the content displaced.
- Taps, double taps, long presses, Shift+drag selection and pinch are unchanged
  by the stretch, including a tap made while it settles.
- A hard flick into the first row or the live bottom ends there, as a
  Chromium fling ends at an update that scrolls nothing: once the bounce has
  settled, the very next tap is a tap (it clicks or focuses), never a brake on
  content that no longer moves.
- Chromium pages on the Chrome backend stretch and bounce under a finger as
  they do under a Mac trackpad: the finger's travel moves the page exactly,
  and its phases (with the glide as momentum) reach Chrome's own rubber band
  through the host's native scroll events. The Alloy backend stops at the
  page edge, as it does for trackpads.

## GE-12 — Graffitty lists, menus, panels and dialog text rubber band

Drag past the first and last row, with a finger and with a Mac trackpad, in:
a touch context menu and its submenus, the mobile menu, the Agents and Sessions
panels (floating and docked), the tab list, notification history, settings
dialogs, the connection page, the Info dialog, Messages and its log, and the
graph delivery details. Each behaves like GE-10: the content follows the
finger (or trackpad) one-to-one while it scrolls, then stretches past the edge
by about a twentieth of the extra travel and settles back on release. A flick
that reaches an edge overshoots briefly and returns. The tab strip stretches
sideways under a trackpad swipe. In a mod with a vertical list inside a
horizontal scroller, a mostly sideways swipe pulls the outer content at
either end. A mostly vertical swipe scrolls the list. Each keeps its axis
through momentum, including when the pointer leaves the list. In the narrow
mobile menu, a sideways drag over an icon scrolls the strip. Holding the icon
before dragging still repositions the floating menu.

- Content that fits can still be pulled; a panel list that fits does not steal
  a pull its enclosing list can scroll.
- Every scrollbar follows the pull as a Mac's does: while content is past an
  end, its thumb shortens by the share of the view left empty and stays
  against that end, then returns with the content. This includes terminals,
  panel lists, menus, settings, and dialog text (Android's overlay scrollbar,
  which never covers the text).
- Mouse wheels scroll in steps and never stretch; a wheel ends any pull.
- A drag that starts on a row, button or menu command scrolls and never
  activates it; a tap made while a pull settles still activates.
- A touch on a list that is still gliding brakes it without activating the row
  beneath. A glide that hits an end stops there with its bounce (GE-10), so a
  tap right after it activates. The Android key strip behaves the same.
- Motion is continuous: no whole-pixel stepping, jumps at the drag threshold,
  or snap at the end of a release.
- On Android, read-only dialog text (a native selectable view, GE-13) moves
  the same way: its drags go through the shared rubber band, never Android's
  own stretch overscroll.

Judge the feel on a phone, a foldable and a Mac trackpad; headless tests only
establish the pull, release and travel distances.

## GE-13 — Graffitty dialog text selection and copy

Read-only dialog text (Info, Messages and its log, graph delivery details,
notification history) selects like a terminal, and has no Copy button.

- Desktop: dragging selects characters; a double click takes a terminal word
  (paths such as `~/project/godot-ghostty` stay whole, following
  `selection_word_boundaries`) and dragging on extends a word at a time; a
  triple click takes the line without surrounding blanks and dragging extends a
  line at a time. Cmd/Ctrl+C copies the selection (everything when nothing is
  selected in Messages); the context menu offers Copy and Select All.
- Android: the text is a native selectable view. A long press or double tap
  selects a word with the system's handles, and the system's floating toolbar
  offers Copy and Select all. The copied text is complete, including Unicode.
  Messages' Open log shows the same in-app viewer as desktop, not a system
  dialog. A vertical drag scrolls (GE-12); after a long press the finger
  extends the selection instead.
- Selecting never scrolls the dialog away under the finger; dragging a desktop
  selection past an edge scrolls toward the pointer.

## GE-11 — Graffitty slow tap on a terminal

With one-finger terminal scrolling, rest a finger on a terminal without moving
it and lift before the long press fires. It is a tap at any duration: a quick
touch and a deliberate half-second one both click once. Held until the long
press, it opens the context menu and the lift adds no click. A double tap still
needs its second tap soon after the first.

