# Floating controls and compact modifier strip

## iOS acceptance scope

Graffitty's iOS/iPadOS 16 client selects the same touch controls as Android.
Apply UI-01 through UI-04 on an iPad in portrait and landscape, including safe
areas and the floating/split iPad keyboard. Hardware modifiers, CJK composition,
keyboard avoidance, app background/resume and saved control positions need real
device checks; Android's Java IME/inset bridge is not used on iOS. Existing Android
passes do not establish iOS behavior. Reuse the remote-client harness rather than
adding a separate runner. Build instructions: `frontends/godot/ios/README.md`.

Shared mobile behavior also includes UI-10 orientation profiles, minimum touch
targets in diagnostics, and haptics when recording starts or a held floating
control/server card starts moving (where the device supports vibration). Verify
camera cursor-follow while the native keyboard remains open in both flat worlds;
it must remain active after typing stops. These checks use the native iOS keyboard,
not Android's EditText reset or Java inset callbacks.

## UI-13 — Optional Flat 3D world on Android and iOS

With no explicit world preference, a new workspace starts in Flat 2D. Open
**View → World** from the mobile menu: both Flat 2D and Flat 3D must be offered,
with the current world checked. Choose Flat 3D, then return to Flat 2D. The same
tabs, pane focus and live shells survive; the menu check follows the selection.
An explicit `[world] path = "flat-3d"` starts in Flat 3D on the next launch.

In Flat 3D, verify rendered terminal text and the 3D typing/tab effects, touch
hit testing, pinch/pan (GE-02–04), and keyboard opening/closing (UI-04). Repeat
on phone and tablet/foldable geometry. Returning to Flat 2D disables 3D rendering
and releases its 3D rendering viewports. The compositor itself may disable 3D in both
modes; Flat 3D's scenery and ink viewports must actually render.

Reuse `android-retained-transitions` for Android/simulated world-menu switching,
live-shell retention and rendered retained text. iOS requires a device run;
Android or desktop simulation alone does not establish an iOS pass.

## UI-01 — Compact key strips (Graffitty and Artemis)

Provide smaller Ctrl/Alt/Shift controls in Graffitty Android and a shorter row.
Do not show Cmd there; the server OS must not change client controls or defaults.
Artemis retains Ctrl/Alt/Shift/Cmd for remote-desktop control. Do not stretch keys to
fill the entire screen width. Maintain usable touch targets and readable armed/locked
states. If needed, scroll the strip horizontally rather than inflating it or clipping
keys. Verify text/icons contrast in normal, pressed, armed, and locked states.

The strip's keys and order come from client.toml `[touch] keys` (default:
Copy, Paste, Esc, Tab, Ctrl, Alt, Shift, ← ↓ ↑ →, Home, End, PgUp, PgDn). Copy
and Paste run the terminal's Copy and Paste actions without consuming one-shot
modifiers. A strip wider than the screen opens at its left end; a wide screen
shows the whole strip right-aligned. Either way the strip slides under a
sideways drag, also when the drag starts on a key: the drag must not tap that
key, latch a modifier, or leave an arrow repeating, and a tap after sliding
activates exactly once. It slides left until its last key is at the screen's
right edge, and right until its first key is at the middle of the screen and
no further, so on an unfolded foldable or tablet the left-hand keys (Copy,
Paste, Esc, the modifiers) can be brought under the right thumb while the
right-hand keys leave the screen. On a phone or a folded foldable the
navigation keys at the right end are reached by sliding left. A flick keeps the
strip gliding and slowing down like the other touch lists. Past either limit
the strip rubber-bands like the terminal (Apple-style): dragged further it
follows the finger with growing resistance, and a flick into a limit
overshoots briefly; on release both spring back to the limit, and a key tapped
right after the bounce taps normally. A strip that cannot slide still stretches
under a sideways drag. With a trackpad, pan sideways over a key and over the
gap between keys. The strip must scroll, stretch at either end, and settle
without activating a key. Touching a gliding strip stops it without tapping the
key under the finger, arrows included. The place is
kept while the keyboard hides and shows; rotating or folding returns the strip
to rest. Configured action keys tap a registry
action and must not consume or alter the one-shot modifiers. Key faces are
drawn by the `touch-controls` mod and must look the same as the native faces
they replaced in normal, pressed, armed and locked states (locked: bold label,
heavier Shift arrow, lock color).

Right-align the compact strip above the visible keyboard without stretching keys;
keep modifier-plus-mouse accessible with the
keyboard hidden. Verify behavior on a phone and a larger/foldable device, portrait
and landscape. Compact dimensions must not create inaccessible keys or consume
underlying pane input.

## UI-02 — Floating keyboard, monitor, and mouse-mode buttons

- Keyboard button opens/closes the IME.
- Monitor button shows the host-confirmed active display number and a compact
  `1 | 2 | 3` chooser containing only real outputs.
- Mouse-mode button has a meaningful active-mode icon and an icon-plus-label chooser.
- `[touch] buttons` chooses which of keyboard, text size and microphone exist;
  an omitted microphone button leaves dictation working without it. Faces come
  from the `touch-controls` mod; a different kind of control is upstream work.
- Round buttons and the `⋯` pill have a clean, even 1 px outline: no dashes or
  bright dots where corner arcs meet, at 1× and fractional scales.
- Buttons use 20% opacity styling. Current implementation interpretation is a 20%
  background with readable icons; visually confirm this matches the requested result.
- Pressed/focus effects have rounded corners matching the control, not a square highlight.
- Ellipsis icons are centered in their hit targets (floating menu and server-card
  actions), including the collapsed pill; do not inherit left-aligned icon defaults.
- New/default buttons cannot overlap existing saved buttons or hide behind the strip.
- Workspace layer order is owned centrally by `WorkspaceLayers`: content, dock,
  desktop transition, menus, window chrome, command line, notifications, then
  floating controls and their pointer capture on top of everything. The floating
  buttons are drawn above embedded windows too (floating panels, dialogs,
  popups, which Godot draws at canvas layer 1024), and a tap on a button over
  such a window reaches the button, never the window, without moving keyboard
  focus into it. The ellipsis menu must appear above either sidebar, including
  while a dock preview is visible. CanvasItem z-index must not be used to
  override layer order.

## UI-03 — Hold to drag and position persistence

A normal tap performs the action. Hold (currently 350 ms) then drag to reposition,
with feedback when dragging starts. A drag must not toggle the keyboard or open a
chooser on release. Accidental movement before the hold threshold cancels the click.
Test pointer cancellation, extra fingers, dragging to edges, and restarting/reconnecting.

Remember unobstructed positions and adapt to keyboard space without permanently
rewriting normal positions. Artemis now uses independent placement: close placement
and overlap are allowed, and dragging a button must never push another button.
This supersedes the earlier request to copy Graffitty's grouping/collision solver.
Graffitty's existing grouping behavior is unchanged by the display-profile work.

## UI-04 — Repeated keyboard transitions must not drift

On both a phone and a different-geometry device:

1. Place buttons near the bottom, side, and center; record screen/window bounds,
   unobstructed reference dimensions, keyboard insets, and displayed coordinates.
2. Open/close/reopen the keyboard at least ten times, including rapid transitions.
3. Repeat with toolbar expansion, Programming Mode, rotation, background/resume,
   and different IME heights.
4. Drag a button while the keyboard is open, hide it, and reopen it.

Expected: buttons remain reachable above the keyboard and return to stable intended
positions when hidden. They must not creep upward or become impossible to drag down.
Temporary IME resize/pan frames must never become a larger/smaller permanent reference
canvas. Do not subtract keyboard space twice. On Android, account explicitly for
`adjustPan`/`adjustResize` and negative window offsets; overlay-managed avoidance must
not compete with automatic system panning.

Graffitty receives Android inset/layout and IME-animation notifications; opening,
closing, changing editor focus and rotating must update the workspace, dialogs and
floating controls without a frame loop reading keyboard height. Check Android
26–29's layout notification path as well as Android 30+'s IME inset path.
After background/resume, dismissal waits for both resume and window focus, retries
at most three times at 250 ms intervals, and releases reserved space immediately.
Explicitly opening the keyboard cancels outstanding dismissal attempts.
Opening the installed SwiftKey Polyglot keyboard in Programming Mode must also
complete its modifier handshake across the two application processes. A private
keyboard Parcelable must never crash Graffitty; malformed messages are rejected
and ordinary text input remains usable. Repeat the ten open/close cycles after
updating both applications, without clearing either application's settings.

The main-area scenario measures visible tab/tool bars, docked panel edges and
keyboard space independently of production fit helpers; the floating menu does
not reserve a full-width row. Verify the actual viewport orientation in both
portrait and landscape, including desktop simulation.

Regression history: a few stable cycles on one phone did not prevent drift on the
other device. Preserve the mixed-device test instead of claiming universal success.

## UI-10 — Four fold-size/orientation position profiles

Both Artemis and Graffitty Android retain four independent layouts: cover portrait,
cover landscape, inner portrait, and inner landscape. Each has its own saved button
positions and reference canvas. Key by physical display size and orientation, never
by keyboard-reduced viewport, app window, or stream resolution. Reverse portrait
and reverse landscape reuse their corresponding orientation profile.
Graffitty iOS uses the same physical-display profiles: portrait and landscape
positions remain independent on an iPhone or iPad, without a foldable requirement.
New profiles start from default positions, not another profile's later edits.
Move buttons differently in all four configurations, cycle them ten times, and
restart the app: each configuration must restore its own layout. Keyboard show/hide,
toolbar changes, and stream-resolution changes must not change the profile.
Rotating or folding during a drag cancels it rather than saving old coordinates into
the new profile. This supersedes the previous rotation-shared two-profile policy.
Unit tests with injected display sizes do not constitute a physical fold/unfold pass.

## UI-11 — Compact slow-connection indicator (Artemis)

Replace the slow-connection text with a small blinking Wi-Fi icon at the top left.
Use the existing connection-quality signal and notification preference. Stop and
hide it on recovery, and stop animation when the app/window is hidden or detached.
Do not intercept stream touches. Check an actual poor-to-good connection transition
and contrast against both light and dark streams; do not disrupt the user's network
or other active streams just to force a warning.

## UI-05 — Chooser buttons are true toggles

Graffitty confirmation-dialog actions form a compact group at the right edge.
On phones, complete buttons wrap into additional right-aligned rows rather than
stretching across the screen or breaking words such as French `Annuler`. Keep
Cancel last and preserve its focus when rotating or changing language. The
session-close action reads `세션만 종료` in Korean. Only local desktop window-close
dialogs offer `서버 전체 종료`; remote/mobile connections never stop the remote
server. Check portrait and landscape, all languages, and keyboard-safe bounds.

Tap the monitor button to open; tap the same button again to close. Test rapid double
taps, slow taps, and a second tap before asynchronous discovery finishes. A late
response must not reopen a dismissed chooser. Test item selection, outside taps,
keyboard changes, and activity teardown.

Repeat for the mouse-mode chooser. Anchor it beside its floating button (choose the
available side, or above/below on narrow screens), clamped to the keyboard-safe area.
It must not open at an unrelated fixed left-screen position. Test after dragging the
button to each edge and with the keyboard open. Only one popup should be active at a time. Popup
dismissal must not turn the same tap into a fresh open request. Confirm rounded focus
and selected-option styling, and no interception of unrelated remote clicks.

Graffitty's main menus, pane-title, hyperlink and Chromium context menus, including
late-created submenus, must use the same rounded popup chrome and opening fade.
Touch menus show outlined unchecked squares or radio circles before focus, with
distinct checked and disabled states. Toggling updates the indicator without moving
the label or replacing a command icon; ordinary commands have no checkbox.
Narrow/compact pane headers retain the title and only the × action, rather than
squeezing a partial toolbar. Widening restores the full action group. The bundled
`pane-header` mod paints this chrome without changing its visual geometry.
With touch controls, a compact (zoomed-out) header shows only its title: no ×,
so a stray tap on a tiny target cannot close a pane; a merely narrow pane at
normal zoom keeps its ×, and zooming back in restores the action group.
Captured pane-header drags use the displayed camera projection, including zoom,
pan and tilt. Drag into another tab/window and back into the source workspace:
the grabbed point stays under the pointer, with no SubViewport screen-transform
warning. Release must reach the original pane even when a hover preview hides it.
Hold a pane or tab over another session's row in the Sessions panel until its
preview replaces the window, then drop. The destination stays on screen with no
camera/tab-switch flight; the hidden source never draws over it (no ghost of the
previous view); and the moved pane
renders live text, never stale texture memory. Repeat in Flat 2D and Flat 3D,
and for drops into a new or existing session without waiting for the preview.
On desktop, at small zoom, click the × where the enlarged title overlaps it:
close must fire exactly once, never begin a title drag. Repeat with tilt, touch
scaling, and after widening; verify left/right and above/below split tap/hold
routing remains intact. On touch, press and hold a split icon until the
reverse split appears, then lift: exactly one pane is created (left or above),
never also the tap's right or below pane.
Workspace tabs on touch: with many tabs on a narrow phone strip, the selected
tab always shows its × beside its number (no hover is needed), and inactive
tabs show only their number. When the tabs cannot all fit at that width, the
strip scrolls instead of hiding the ×. Tap the number to select and the × to
close; neither tap may trigger the other.
Queue Inspector on touch: tap a graph wire to open it. With deliveries flowing,
the dialog must hold one steady layout and scale (no alternating frames). Toggle
**Pause connection**: the wire turns dotted, pending messages are cancelled, and
the switch follows a pause/resume made from desktop while the dialog is open.
Graph ports use the pane's projected height and actual touch targets, rather than
a zoom cutoff. At a three-terminal overview, spread all five outputs if their
44-logical-pixel targets can remain separate; only compact when the pane is too
short. Five outputs fit a 200-pixel pane even at quarter zoom. Zoom/pan and tilt
must keep wires attached to the displayed ports, preserve the selected output,
and avoid overlapping targets. At smaller heights, retain the compact port picker.
Repeat on phone and foldable in both orientations; desktop uses 28-pixel spacing.
Wire menu on touch: press and hold a wire (also slightly beside it) until the
menu opens, with no pan or pane drag. Check **Pause connection** turns the wire
dotted and the next hold offers **Resume connection**; **Remove connection**
shows a trash icon and red text (also on desktop, where this menu is app-drawn instead of an OS menu), and deletes only that directed wire. Holding on a reroute opens the reroute menu instead.
The pane-title menu marks each split item with the split icon plus an arrow
toward the side the new pane takes; header icons stay plain.
The pane-title
menu groups Rename/Fit, then Left/Right/Above/Below splits, then Filetree/Chromium/
Pane status, and finally Close alone after a separator. Reopening and late
pane metadata must preserve this order; non-terminal panes omit terminal-only
items without empty groups. It displays resolved configured
shortcuts for every bound action, including filetree. Filetree pane titles use
the server-side home directory (`~` or `~/…`), preserve literal `%` characters,
and do not abbreviate sibling paths that merely share a home-directory prefix.
Pane titles have no running/busy spinner: the title already conveys running
state. Preserve the static waiting/blocked indicator when no status strip owns
it; agent-list/status-strip indicators are unchanged.
Pane-title Close has a red trash icon and red text, plus the resolved client ClosePane binding (by
default Ctrl+Shift+W on Android), never a hard-coded Meta+W hint. Styling must
not change command routing, dismissal, enabled states or keyboard navigation.
Right-clicking a session in either the full or compact Sessions panel opens
Rename Session and Kill Session, without selecting that session. Rename edits the name in the row. Enter or an outside click saves it. Escape discards the draft. Compact session rows show the name on hover. Compact agent rows show computer, session, and agent title. Expanded titles show a tooltip when truncated. Kill Session
uses red text and a red trash icon and opens confirmation focused on Cancel.
Cancel preserves the session; confirming ends only that session on its owning
server. Other sessions and the server remain running. Killing the session a
local window displays keeps that window open and switches it to another live
session no other window shows (its previously viewed session first); it closes
only when every remaining session is open elsewhere, and the app quits only
when nothing is left to show. Repeat for local and remote
groups that contain the same session ID. These destructive menus are app-drawn
on desktop too. Their labels fit when opened from docked or narrow floating
panels; native menus may extend past the panel while staying within the screen.

Android menus remain compact popups (at most 320×360 logical pixels, further
bounded by the keyboard-safe viewport), with scrollable overflow and truncated
long labels. `PopupMenu` retains the command model; one shared `TouchMenu`
presenter owns layout, scrolling and activation across main menus and context
menus. Rows must not independently compete for touch ownership. A drag across
rows clears highlights, scrolls at the UI scale, and never activates an item on
release. Canceled touches and extra fingers also cannot activate items. A fresh
tap must still select exactly once. Submenus reuse the bounded presenter with a
Back row; disabled/check states, shortcut hints and command IDs remain intact.
A shortcut hint sits right-aligned in its own reserved space; a long command
name is trimmed before it and never draws under the hint.
Other desktop native menu behavior is unchanged. Cover phone/foldable, portrait and
landscape, non-integer scaling, long translations, and keyboard-visible bounds.

Android Back while any workspace menu is open closes the menu/submenu stack and
collapses the expanded floating menu, consuming that Back without opening the
workspace manager. A later Back may navigate normally. Entering the workspace
manager by any other route must also dismiss workspace popup windows: the manager
and workspace menus must never remain visible together. Verify the main menu,
nested submenus, pane-title and hyperlink menus; do not treat hiding their parent
workspace Control as sufficient to hide popup Windows.

## UI-07 — Command line and persistent Agents window

Tab-menu rows and command completion rows are rendered by the bundled
`tab-menu` and `command-line` mods. Native hosts retain keyboard navigation,
IME/text editing, touch ownership and activation. Verify tab pane-count taps,
drag cancellation, refresh during scrolling and completion matching after mod
rendering; a repaint must not steal focus or run a command twice.

New Agents, Sessions and Pane Status panels start docked left. Dragging out
floats those panels, and explicit saved placements or closed states override
defaults. Status Line is a titleless top/bottom bar, initially at the bottom;
it cannot float or fold. Exercise the floating-window checks below on panels
after undocking.

On a narrow phone and a foldable, in portrait and landscape, open the prefix
command line with the IME visible. Suggestions must page within the available
height; the input, selected completion and status must remain on screen even for
long labels. Select `Agents` through this command line, not a direct test action.

Each agent row group has a small, muted caption line above it: `server · session`
for remote agents and only the session name for this computer. The session uses
the user-set name, otherwise the server's automatic name, otherwise its ID.
Consecutive rows within a section sharing the same server/session show one
caption, so they read as a group; a change of either part starts a new caption.
No server label sits inside the row; long captions truncate with a tooltip.
Verify agents with identical titles on two remotes; selecting each must focus its
own remote/pane. Hover may swap the time for Pin.

Agents is a non-modal, draggable, resizable window. Touch-drag its title and drag
its unlabelled bottom-right resize area; assert width **and** height change, not
merely that the size differs. There is no triangle or Test sound control.
Selecting an agent focuses its pane without dismissing Agents;
tapping another pane must allow normal terminal input while the list stays open.
Re-running `:Agents` raises the existing window. The title × closes it. Open and
close the keyboard repeatedly: do not dismiss it merely because a read-only,
non-modal window exists, keep the list reachable, and restore unobstructed geometry
without drift. Recheck after rotation. Record actual device evidence separately
from desktop-injected touch tests.

## UI-08 — Persistent Sessions window

Open `:Sessions` through the keyboard-safe command line, and through
Sessions → All Sessions. Confirm This computer first, then every connected or
saved remote, grouped by server rather than duplicated per attached session.
Group headers and compact strips use the server's reported macOS/Windows/Linux
icon, retaining saved platform metadata offline. Unknown platforms use a neutral
monitor, never a guessed OS or generic server-rack icon.
Connected dots are green/yellow-green; offline dots are gray and do not show
stale sessions as available. Fold/unfold groups. Select sessions with identical
names on different servers and confirm the correct server and session receive
subsequent input. Session selection leaves the window open; reopening raises it.
Pan and zoom differently in two sessions, then switch immediately between them:
each session restores its own viewport, including its tab views, without resetting
to Main View. Repeat through `$session` and CLI attachment. A session left fitted
stays fitted; newly created sessions start fitted. Other windows keep their own
views, and a rejected switch does not change the current camera.
Compact session labels show actual server session IDs without the `$` prefix, not
list ordinals: gaps such as 0, 2, 3, 4 remain intact within each server group.
The per-server + opens the existing new-session flow for that server only.
With enough rows to overflow, swipe starting on a session button, group header,
and blank list space. All must scroll, without switching sessions, folding groups,
or opening a server. Repeat after list refresh, in compact mode, and after docking
or undocking. A fresh tap after scrolling must activate exactly once. The shared
scroll owner must follow the live content into its new viewport; footer actions
and scrollbar dragging retain their own input handling. Repeat for Agents.
Use dense list spacing (4-pixel body insets, 28-pixel agent rows and 32-pixel
session rows), with no empty resize footer. Hide **Add server** entirely on mobile.
On desktop hide its footer when fewer than five session rows plus a group header
would fit with the action present; use viewport capacity, not the number of saved
sessions. Resizing across that threshold must not oscillate. When shown, the
footer says **+ Add server** and opens the normal workspace manager.
Desktop and Android share the same responsive server-card browser and separate
editor page, not a desktop-only two-column manager. Verify 320/390/840-point widths,
Back clearing unsubmitted passwords, and closing the manager without disconnecting
live sessions. Connection cards show server identity, address and connection status
only, with no session label or number. Last-session, tab, focused pane and camera
selection remain internal view preferences: returning through the manager or
reconnecting restores the previous view without displaying those details on cards.
Desktop-only local-return/startup/new-window actions remain available. Give the
button real layout width: a clipped label in a zero-width control is not a visible
action. Keep it pinned outside the scrolling list. In compact mode, when the
platform/height policy permits it, show **+**, with localized **Add server**
tooltip/accessibility name; hide the spacer and resize grip. It must fit the 44-pixel
rail without widening it. Verify visible bounds and activation at 1× and 1.5×,
floating and docked, through repeated narrow/wide transitions. Opening/error status
appears above the footer without moving or resizing its Add server button.
Drag saved-server headers in Sessions, or server cards in the workspace manager,
above/below another saved server to reorder. On touch, hold 350 ms before dragging;
ordinary swipes must still scroll. Workspace-manager card bodies have no tooltip
repeating their name, address or connection status, including while held
still before or during reordering. Keep those details visible and available in
the card button's accessible name; retain the separate Server actions hint.
This shared card behavior applies on desktop, Android and iOS.
In the workspace manager the card itself lifts
(raised, slightly enlarged) and follows the pointer; the other cards slide apart
to show where it will land, and it glides into that gap on release. Holding it
near the top or bottom edge scrolls the list. Releasing must not open the
server; Escape or a second finger returns the card to its place. The same
saved order must appear in both views immediately and after restart, with This
computer fixed first in Sessions. Move all saved sessions of a server together;
preserve credentials, selected sessions, live connections and folded groups.
Check canceled drags, extra fingers, focus loss, scrolling before the hold, and
failed saves; none may silently reorder or trigger a connection/group toggle.

Repeat UI-07 movement, both-axis resize, keyboard-cycle and narrow-screen checks
for Sessions. Agents and Sessions share floating-window chrome and geometry;
regressions must be checked in both. Offline servers lead to the existing server
manager; this must not clear credentials or silently connect without the normal
authentication path. The automated multiserver fixture covers grouping and
selection; it does not establish physical-device touch usability.

## UI-09 — Shared list docking and workspace/manager isolation

Status Line is a special bar: no title row, close button, folded state or
floating window. Verify status content is visible at 32 pixels and after
resizing above 100 pixels using the actual inner edge. A click, double-click
or double-tap must not hide or detach it; its feature buttons remain clickable.
Drag its background bottom-to-top and back, preserving its height. Release in
the middle, outside the window, or cancel: keep the original dock. Only the
View → Status Line toggle hides it. Toggling back restores its edge/height.
Restore a saved folded bar and verify its contents are shown; a disallowed
floating placement must use its default dock. Check desktop mouse and Android
touch paths independently, at 1× and non-integer scale. Reuse
`status_line_smoke.gd` (mouse and `--android` touch injection) and the existing
Android docking harness for physical acceptance.

Click/tap a docked panel title without moving: only that panel folds to its title.
Tap again to restore its expanded proportions; adjacent panels use released space.
Repeat for top/bottom bands and native/embedded floating windows. A floating panel
rolls up without moving its title and restores its previous size. Close/reopen and
restart the frontend: folded state survives. Drag beyond the movement threshold,
return to the press origin, then release: it must remain a drag. Canceled touch,
Escape, focus loss, close-button clicks and a second contact must not fold.
Test at 1× and non-integer scale, including a press/release within a single frame.
Floating panels use application-drawn titles; folding must not depend on global
pointer polling, including on Wayland. Touch-emulated mouse events must not
cancel or duplicate a tap. These checks are separate from shrinking an entire
sidebar into a compact rail.

Translucent mod panels blur the parent scene both docked and floating embedded,
using `background_blur_radius` (0–64; 0 disables). Verify at 0, 12 and 24 while
moving/resizing, docking/undocking, rotating, and switching workspaces. Text and
controls must stay sharp, with no doubled tint, stale blur rectangle, pointer
interception or capture feedback. Closing/hiding removes the floating backdrop.
Other embedded windows are composited later; their content is not part of the
parent-scene blur. Desktop renderer/fixture tests are not physical-device passes.

On desktop, Agents, Sessions and Pane Status float in **real native, resizable windows**.
Drag the application title to an edge to preview docking; release to dock. Leave
the preview and continue moving; release outside the workspace and cancel with
Escape/focus loss. Native preview must retain its original input stream until
release. Test OS-delivered mouse events separately from viewport injection.
There is no docking button. On Wayland, native movement and edge resizing use
the compositor; global-position docking is not available. Docking reserves
**main content only**:
menu and tab-strip widths must not change. Sidebar outside margins and spacing
between stacked tools use the client's configured tiling `gap`, including zero.
Apply this to Agents, Sessions and Pane Status on desktop and mobile. Reserve
the outside margin with the sidebar width, without doubling the main tiling area's
own gap. Changing the gap must update both live panels and previews; narrow rails
retain their minimum panel width and resize targets. The invisible sidebar width
resize target spans the entire configured gap and extends into both the sidebar
and adjacent terminal (5 logical pixels on desktop, 16 with touch controls). Dragging
from the outermost terminal edge resizes the sidebar on either side, instead of
starting a terminal resize or workspace gesture; no visible vertical bar is added.
The preview must equal the committed
rectangle, including above/below insertion into an existing stack. Move the actual
live controls and their actual title header into the read-only preview while
neighbors rearrange immediately, not a blue overlay or a duplicated snapshot.
Expanded previews include the title; narrow strips keep the header hidden.
Preview layout is owned by the destination side and extent, not the source window's
width or committed side. Hover through compact/expanded top/bottom bands and
narrow/wide side rails without dropping: Pane Status must show the destination's
row/rail/readout, and Agents/Sessions the destination's list form. Side panels
turn compact only below 80 logical pixels wide (floating or docked, phone or
desktop); a 120-pixel sidebar still shows full names. Repeated drag
frames and deferred container resizing must not revert the form or inflate preview
bounds. Cancel restores the source layout; commit preserves the preview's form and
bounds. Repeat from floating and already-docked sources. The
dock/preview header is 20 pixels tall with 11-pixel text; embedded floating chrome
is 24 pixels with 11-pixel text. Native OS title bars keep their system metrics. The source floating window (or old
dock) must disappear while the target preview is active. Status/time changes must
remain live. Moving outside the target restores the floating presentation under
the pointer without ending the drag; release commits, Escape/canceled touch
restores it. Leaving the workspace or closing a panel mid-preview must not leave
an orphaned preview, lose its content, or show a panel on the manager.
Drag docked
titles to reorder, move sides, or detach into a native window. During detachment,
the pointer must remain in the floating title bar, not jump into the body; fitting
the window to a display must not change the grab position mid-drag. Drag inward edges
to change sidebar width and horizontal dividers to change stack proportions.
Proportions survive main-window resizing. Hovering/dragging a divider shows the
correct resize cursor. The vertical sidebar resize edge is completely invisible,
including on hover and while dragging. Horizontal stacked-panel separators are
also completely invisible, with no line or bar. Their hitboxes span the full
configured gap and extend into the preceding panel (5 pixels desktop, 16 pixels
mobile), without stealing the next panel's title/close controls.
Check the gap center and both edges, including zero and large configured gaps;
these touches must resize the stack rather than drag a title or reach a terminal.
Obvious resize, title-drag and close controls have no hover tooltips; retain their
accessible names. The shared dock close button has a red background and white
close glyph on hover/press, returning to transparent when the pointer leaves.
Keep full-name/status/pin tooltips and command/shortcut hints.
Escape cancels dock drag/resize. The sidebar can shrink to 40 pixels, with a
44-pixel collapsed width. There are no expand/collapse arrow buttons; drag the
inner resize edge outward to expand. Under 160 pixels hide titles/groups and
show numbered compact rows (agents retain status glyphs). Strip padding must not
force a wider minimum, including when the list needs a scrollbar. Reopening via
its command can restore the last expanded width. Closing the final dock releases
its inset. Reopening restores its last side/order/proportion; restarting restores
saved open/folded panels. View → Agents and `:Agents` use the same list.
The tab-chevron tooltip names `:ShowAllTabs`, which opens that same menu.
Check Chromium, session switches, HiDPI, small-window fallback and independent
layouts in two application windows. Cross-main-window merging is not implemented.
Double-click the main custom title area to maximize and restore its previous
size/position, not enter fullscreen. Native floating title bars use OS double-
click handling (including OS preferences); verify it on each platform.

Pane Status uses the same docking/window lifecycle, not a separate draggable
overlay. Pane Status, Resource Monitor and the status line also support top and bottom docks:
drag to either horizontal edge of the terminal main area (the top is below the tab
bar). The status line is top/bottom-only; Agents and Sessions remain left/right-only.
Both destinations span only the space between the sidebars, respecting the
configured gap; sidebars keep their full height. A band holds several panels:
dropping on a band panel's left or right half places the dragged panel beside it
in the same row; dropping at the band's outer edge adds a row above (top band) or
below (bottom band) the existing rows. Each row's terminal-facing edge resizes
that row alone, so a status line can be one line or two while the monitor keeps
its height; the invisible divider between side-by-side panels changes their
proportions. Rows, placement and heights persist. The Sessions, Agents, Pane
Status and Resource Monitor contents and the status line are JavaScript panels drawn from one Rust draw
list (docs/developers/automation-and-extensions/mods.md); their text cannot be selected or copied.
The invisible terminal-facing edge resizes height: drag down for a top dock or up
for a bottom dock to grow it. It blocks terminal gestures across the gap. On
touch it reaches fully into the gap but only a quarter of a thin band's height,
so a compact status line's switches stay tappable. A compact band has no title
row: a finger on one of its controls presses it, and only its passive areas
(labels, padding) start a move/undock drag. Preview,
cancel, undock, close/reopen, manager isolation and persisted placement/shared band
height use the same lifecycle. Resizing the application must never float an
already docked panel, even below the preferred content size. Keep dock ownership,
preferred widths and stack proportions through shrink/expand cycles; only an
explicit undock action changes ownership. Terminal layout, pointer hit testing and camera
framing exclude all reserved edges, including during zoom and dock resizing.
Verify neither/either/both sidebars, moving between top and bottom without stale
reservations, narrow phones, and insufficient-height retention of existing docks.
Reject new dock placements that cannot fit, rather than detaching existing panels.
Both targets are 32 logical pixels on desktop and 56 with touch controls.
The monitor follows the focused terminal/Chromium pane without losing its placement
when changing worlds or sessions. It re-renders only when a published value changed.
Do not show Select all, Copy selection or Resume updates buttons, a paused warning,
the copy-instruction tooltip, or the sampling interval.
Long readouts wrap and scroll
without resizing the user's window. A compact rail shows CPU and memory values using
the same icons as the status strip, with six logical pixels of padding on each side.
At minimum rail width, icons stack above values; wider compact panels place icons
beside values. Show the focused pane ID and the shared agent/node badge too, including
provider/node identity, status and available duration/history. Clear the previous
badge when switching to a pane without an agent. Keep full details in the tooltip.
A top/bottom band shrinks to 32 logical pixels. Below 100 logical pixels it hides
its title row and shows the same pane ID, CPU/RAM icons and values, and agent badge
in one status-strip row. Normal CPU values must not shift the row. With no title row,
the body is the move/undock drag target (double-click floats). Growing the band
restores the full readout. Verify docking beside/above Agents and Sessions, live
updates, close/reopen and saved placement, manager isolation, and zero input leakage.

Android retains the Godot embedded Window but now shares docking and persistence.
Dock layout follows panel minimum-size, visibility and host geometry changes.
After the layout settles, an untouched panel must not keep recalculating its
layout. Resource samples, pane changes, connection state and saved-server edits
must refresh their mods immediately through notifications, including while docked
or folded; opening a panel must not be necessary to refresh stale data.
Floating mobile dialogs have no painted resize border or triangle/grip. Only
left/right/bottom edges and the two bottom corners resize, using invisible
16-logical-pixel hit areas. The top edge and top corners never resize: they remain
available for normal title dragging (and the title close button). Native desktop
windows retain their OS resize behavior on every edge. Verify axis-correct resizing,
minimum sizes, viewport bounds, cancellation, and 1×/1.5× input coordinates.
Title-drag to an edge to dock, resize sidebar width and stack proportions, then
undock into a reachable floating window. A floating window may be pushed partly
off the screen (a phone has no room to keep every window whole); only a
44-logical-pixel piece of its title must stay inside the usable area, and the
title row may never leave it vertically. Dragging it back makes it whole again.
The keyboard inset applies the same rule: the title stays above the keyboard,
the body may not. Verify larger
touch targets and enough remaining main content on phone-width screens. Drag at
1× and non-integer UI scales: the floating title must follow the same finger
one-to-one, with no acceleration or grab-point jump when leaving a preview.
Empty mobile edges have a 56-logical-pixel docking target. Undocking must start
following the finger before release, rather than teleporting on release. Repeat
UI-07/UI-08 keyboard, rotation and focus tests on phone and foldable.

With a left dock, right dock, both docks, and after changing their widths or
closing them, repeat typing zoom and manual zoom/pan. The **entire cursor cell**
must remain in the unobstructed main-content rectangle, not merely inside the
full window behind a sidebar. Preserve one full-window projection/input coordinate
system; apply asymmetric viewport bounds to camera following rather than adding
widget-specific cursor offsets. Check actual rendered cursor pixels, pinch-anchor
round trips, and that camera effects never modify saved manual navigation.
With Effects → Zoom mode → Adaptive zoom, fixed typing zoom must not stack with
content fitting. Launching and quitting nvim (alternate-screen clear followed by
progressive repaint) must not oscillate in/out: content growth reframes at once,
while a smaller footprint is adopted only after it has stayed unchanged for
600 ms. A real `clear` therefore still retargets. Type into a sparse pane while the workspace is zoomed far out:
fit that pane's tracked content with breathing room, without modifying saved
manual navigation. Grow and clear output during the typing hold; each change must
retarget an animated fit. Dense content uses less automatic magnification than
sparse content, but typing must never shrink below the resting manual view just
to fit padding. Test full-grid content with and without docks, and existing manual
magnification above the automatic cap. A dense pane viewed from overview should
still approach a useful scale. Repeat with side/bottom docks, keyboard insets, alternate screens, and
switching focus between panes. Idle returns to the original overview; selecting
Typing zoom restores the fixed authored behavior. Verify both Flat 2D and 3D.
Enable pane enlargement, tilt, drift and saddle curvature together, with asymmetric
docks. Final projected tracked content must remain in the usable area; reduce tilt
before widening the view. Only real geometric overflow, not comfort padding, may
require a final scale below the resting view. Check every animation frame, actual
rendered edges and inverse hit testing. Particles/glow outside content are not fit
bounds. Exercise changing content and turning individual effects off without jumps.
Cursor containment must hold throughout each zoom frame, not only after the camera
settles. Repeat with cursor jumps to both pane edges while typing, and dock width
changes while zoomed. Use the same unobstructed workspace-region geometry for fit,
inverse projection, pointer hit testing and non-pointer pane placement; sidebar
pixels must not become available main-area space. Do not warp the OS mouse to hide
coordinate errors. Terminal IME anchors are bottom-left, not cell centers.
Touches starting anywhere over a dock (title, rows, blank body, resize edges or
preview) must not acquire workspace pan/zoom ownership or send input to the pane
underneath. This also applies when another finger already owns a workspace gesture.
Keep panel ownership through moving outside its bounds and release/cancellation;
repeat for Agents and Sessions, floating and docked, including shifted canvas layers.

Connection Manager, connection Editor and Workspace are mutually exclusive
presentation states. Test leaving with one list floating and one docked: neither
list, menu, resize target nor workspace may remain visible on connection pages.
Returning restores both without changing geometry or terminating sessions. Agents
is owned by the application Window, not a transient terminal host; session switching
must not destroy it. Device harness lookup must use that same owner.

### UI-09R — Resource Monitor table

**View → Resource Monitor** opens the all-pane table (bottom band by default; any
side or floating, with the shared docking lifecycle above). With at least two
windows and a remote session open:

- Every pane of every window is listed once, with the program icon, title, pane
  (`%N`, sorted by number), CPU, RAM, process count, root PID, Server and Session. A caption over consecutive
  rows names `Server · Session`; a pane closed or opened anywhere leaves or joins
  the table without reopening it. Unknown samples show `—`, never `0`.
  The process-count header is intentionally `#procs` in every locale, including
  Korean; only its explanatory Processes tooltip is translated.
- Clicking or tapping a row raises its window and focuses the pane.
- Clicking a header sorts (natural direction, reverse, list order), with an arrow
  for the direction; dragging a header lifts the column under the pointer while the
  others slide aside, without jumps, and past half of another column it lands there;
  dragging the right edge of a header resizes the column, with a horizontal-resize
  mouse cursor on the edge and throughout the resize. Leaving the panel does not
  commit or cancel a header drag, resize, or horizontal-thumb drag: it resumes on
  return, and only release ends it (including release outside).
  None of these gestures triggers another, including on
  touch, and none leaks to the workspace underneath.
- By touch, a header moves or resizes only after the finger holds still for about
  half a second; an immediate slide scrolls instead.
- On a panel narrower than the columns (a phone in either orientation), a finger
  sliding sideways scrolls the header, rows and totals together, with a thumb
  showing the position; dragging that horizontal thumb must scroll header, rows
  and totals together, not focus a row. Mostly vertical slides scroll the rows only. A trackpad,
  horizontal wheel or Shift+wheel does the same on desktop. A slide that leaves
  the panel keeps scrolling it, and no slide focuses a pane.
- The funnels on Server and Session open opaque checkbox lists that stay open
  while ticking. All ticks every value; unticking values hides their rows; ticking
  them all is All again. With one server chosen, captions show only the session.
  Choosing servers clears the session filter.
- The rows scroll by wheel, trackpad, finger and by dragging the visible scrollbar
  thumb; the header and the totals row stay. The totals cover the shown rows:
  across several servers CPU is the mean of each server's total.
- The panel is translucent docked, embedded and floating: the workspace or desktop
  shows through (blurred when `background_blur` is on), the text stays readable,
  and the filter list stays opaque.
- Column order, widths, sort and filters survive closing and reopening the panel,
  other windows, and an application restart.

## UI-12 — Restore the last Android connection

After successfully opening a saved server, switch to another app and return.
A temporary network loss must keep the workspace, selected tab/pane and dock
layout visible, with offline status, while the existing transport retries.
Disconnected input must not be queued for replay. Repeat with multiple remotes,
a network/VPN interruption and ten background/resume cycles.

Recreate the Android process and launch again: automatically connect the last
opened saved server, restore its last session/tab/pane using the existing view
state, and open it after authenticated topology arrives. Use only existing
remembered credentials from the vault; missing/expired credentials or required
verification must still use the normal sign-in flow. Never persist plaintext
passwords in navigation state or resurrect a removed/transient server.
New connection editors leave the session field blank. Blank/omitted session
selection must never create or assign the name `main`: use a remembered/existing
session, or the server's automatic name when none exists. Explicitly typed names
still work. Existing named sessions are not silently renamed.
Explicit Disconnect clears automatic startup selection. Opening the manager or
editor while a connection is pending cancels automatic workspace opening, without
terminating the connection. Returning from another app while deliberately on
those pages must not force a switch to the workspace. Desktop startup preferences
remain unchanged. Record phone/foldable and real process-recreation evidence;
unit tests are not device lifecycle acceptance.

## UI-06 — Live microphone compression and stop/cancel boundaries

The live microphone sends stateful mono Opus (48 kHz, target 32 kbps, 20 ms
frames batched every 100 ms) over the authenticated client/server connection.
Only the server decodes/resamples to provider PCM; live PCM uploads are rejected.
Verify live preview before release, hold/release and latched Stop, a short isolated
word, and a partial final frame. Stop must drain capture and flush codec delay;
pre-skip and final padding must not shorten speech or add provider silence.
Stop during provider setup must retain queued Opus and its final codec tail.
Cancel/slide-away must discard the stream, and a new recording must reset codec
state. Queue stalls, malformed/out-of-order batches, incomplete final batches,
and the ten-minute decoded duration limit must fail without submitting text.

Use `tests/android/dictation_e2e.py` for real Godot/server transport with synthetic capture
and a provider fixture; it also asserts that the wire payload is compressed.
Rust codec/RPC tests cover exact decoded sample counts and protocol rejection.
These are not physical-device microphone passes. On Android, repeat short-word,
stop-during-setup, cancel/restart, and delayed-network cases using actual capture,
recording build/device and observed transcript/timing outside the repository.

On iOS/iPadOS 16+, use the same physical-microphone cases and verify the native
permission prompt (grant, deny, dismiss/cancel while pending, retry after enabling
Settings permission). Stop/cancel/start must release and reacquire the microphone
without capturing samples from an earlier recording. Interrupt recording with
an incoming call/audio interruption and background/foreground the app: the active
capture must fail/cancel rather than silently submit partial audio. Confirm the
previous playback audio-session category/mode/options are restored on normal stop,
cancel and device-open failure; check speaker and Bluetooth microphone routes.
The prompt must use the selected device language. These checks require a physical
device and are not implied by desktop capture tests or an iOS signed build.

### UI-06C — Optional client-side Gemini credentials

The connection screen Settings dialog configures a device-local key. When present,
this key overrides the server-side API key: no dictation RPC or key is sent to the
server, even when server dictation is disabled. Authentication/provider failures
must not silently switch to server credentials. Use server clears the override.
Keys must remain in the OS vault/Android Keystore-backed storage, not plaintext
settings, exports, logs, or URLs. All dialog text must be localized.

Direct mode buffers mono PCM16 locally (maximum 60 seconds) and submits WAV to
Google after Stop; unlike server live mode, it does not promise interim preview.
Verify Stop, empty speech, cancellation while waiting, focus/session loss, bad key,
quota errors, key replacement/clear, and a server with dictation disabled. Confirm
redirects cannot forward credentials elsewhere. Reopening settings must not reveal
the saved key. No completion may type into a different terminal.

Current evidence: native protocol unit test, Godot protocol/settings-load test,
Android companion tests/build, and prerecorded direct-provider transcription.
Device-level configuration and microphone checks for this mode remain pending.

### UI-09 — Workspace manager connections and mobile start

Tapping a saved server connects it without leaving the manager. Tapping an
already connected or connecting server keeps the manager open and its transport
intact. Connect multiple servers individually, including password entry, then
verify that their connections remain active. Connect all sits beside the connected
count, skips existing attempts, and opens the terminal when a server is ready.
Failures must remain visible without dropping successful connections.

A saved connection contains server identity and authentication preferences only.
After sign-in, the server lists live sessions and the client restores its own
last session, tab, focused pane, pan and zoom. A missing remembered session
selects another live session without a password error. An empty server remains
connected and creates a session only after an explicit start/new-session action.
Closing its last session clears dead panes while preserving the connection.

On mobile, the Graffitty logo stays horizontally centered in the header. While at
least one server is connected, a compact Touch to start speech bubble points to
the logo. The logo and bubble are one start action; both must respond to a tap.
The bubble sits entirely beside the logo on its right, vertically centered with
a left-pointing tail, a minimum 48-logical-pixel height and expanded touch bounds.
On narrow screens the centered logo shrinks to leave room for the translated
prompt. The bubble sizes to its available space, never fills the header, and
translated text stays readable on phone and tablet in portrait and landscape. Disconnecting
the last server removes the bubble and disables the start action while keeping
the logo centered. Starting opens a connected workspace. Desktop has no start
button; closing the manager returns to the terminal.

Physical-device acceptance remains pending.

### UI-09S — Side-panel scrollbar fades

Overflowing mod lists (Agents, Sessions and Resource Monitor) show their thumb
with a 120 ms eased opacity transition when the pointer moves over the list or
scrolling begins. After 1.2 seconds without activity, opacity fades out over
280 ms. Pointer exit fades too; a recent scroll retains its idle grace period.
Resuming activity halfway through a fade reverses smoothly from the current
opacity. A held thumb stays visible, and releasing it restarts the idle delay.
Content width, row positions and scroll offset remain stable while opacity
changes. Once the fade finishes, the scrollbar requests no continuing redraws.
Verify wheel, trackpad, finger scrolling and thumb dragging; a hidden thumb's
existing grab area remains available.

### Dictation stop while a provider is silent

After the microphone tail is drained, the microphone action and draft editor must
remain usable while final transcription is pending. Editing cancels that pending
result; a second stop/send accepts the current draft (or dismisses an empty one).
A superseded result must never overwrite the draft or insert text into a pane.
Quiet speech must remain intact; do not use an amplitude cutoff to discard it.

## UI-14 — Side panel visibility

In Graffitty, open a side panel and the status bar, then use
**View → Toggle Side Panels** or an external keyboard's Ctrl+Shift+B
(Cmd+B on macOS/iOS).

- Both disappear and the workspace uses the released area.
- Toggle again: restore the same panels, positions, dimensions, and content.
- Keep terminal processes running; do not close panels or overwrite their saved layout.
- Switch to the server chooser and return while hidden: panels stay hidden.
- Open another panel while hidden: it appears only after restoring panels.
- Other application windows retain their own visibility state.

Reuse `frontends/godot/project/tests/list_docking_smoke.gd` for dock lifecycle
coverage. Desktop headless checks do not establish Android/iOS device acceptance.

Font shortcuts after touching floating controls must resize the focused terminal.
A touch-emulated mouse position over a docked panel must not redirect Ctrl+=,
Ctrl+-, or Ctrl+0 to that panel. Moving a physical mouse over the panel restores
pointer-targeted panel zoom. Verify both input sources.

The IME/messages dismissal fixture expands the compact dock row into its
floating window before tapping Dismiss. Compact rows use their close chrome.
Floating-control persistence checks read the current physical-display profile,
including portrait/landscape geometry, rather than the default profile file.
