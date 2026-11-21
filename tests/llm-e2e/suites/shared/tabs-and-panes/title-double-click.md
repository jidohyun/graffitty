# Title double-click navigation

Launch `mise run dev -- --shell=/bin/sh` with an isolated test config. Record continuous motion for animation checks, capture before/after layouts, and report PASS, FAIL, or BLOCKED with observations. Use actual title-bar clicks, including the first click of each double-click; do not substitute a menu command or API call for the behavior under test.

## First launch without view history

Before any navigation in a fresh session, double-click the already fitted pane title. Animate to a centered view fitting it within 30% of usable viewport width and height, preserving aspect ratio and pane geometry. Double-click again to restore the fitted view. Repeat by mixing the title double-click with Command+Enter on macOS or Ctrl+Shift+Enter on Linux/Windows; both must use the same saved view.

## Single pane and clicks

Start with one tiled terminal, label it ALPHA, and note `echo $$`. Zoom out and pan off center. Click its compact title once, hold briefly without moving, then release. It must keep its tiled rectangle and membership throughout the press and release. Tiny pointer jitter must not detach it. Double-click its title: the camera must animate back to Main View, with the whole main area visible. Double-click again to restore the exact off-center pan and zoom. The pane must not move or resize. Repeat on its normal title bar at readable scale. Ordinary focus changes are allowed; a single click must not change tiling or navigation. Confirm a deliberate title drag still works, then restore the layout before continuing.

## Two panes at every zoom

Split ALPHA horizontally into left and right panes. Label the new pane BETA and note its PID. From a small overview, normal scale, and an enlarged view with the title still visible, single-click then double-click each title. Both panes span the main area's height, so the first double-click from a distinct view must animate to Main View. The next double-click must restore that exact previous view. The first click must not remove the pane from tiling or shift the title away before the second click. Check for a visible intermediate camera position and a smooth arrival, with no snap or leftover drag.

Repeat in another tab with a vertical split: top and bottom panes span the main area's width, so both must return to Main View. Normal tiling gaps count as part of the main-area framing; they must not cause an individual-pane zoom.

## Three panes and interruption

Return to the left/right layout and split BETA vertically, making one full-height pane on the left and two half-height panes on the right. Double-click the left title: show Main View. Double-click either right title: animate to fit that individual pane below the toolbar, with its full title and controls visible. Repeat with compact and normal titles.

Return to Main View and focus a smaller right pane's terminal. Press Command+Enter on macOS or Ctrl+Shift+Enter on Linux/Windows without a prefix: **View → Fit to Pane** must animate to the same framing as its title double-click, retaining keyboard focus and leaving pane geometry unchanged. Double-click to return to the frame saved by the shortcut, then double-click to fit and use the shortcut to restore. Repeated double-clicks must toggle instead of continually fitting.

During a fit animation, pinch or use Command/Ctrl-scroll to zoom manually. The camera must follow the new input immediately and must not jump to the old animation target later. Repeat by choosing View → Fit to Main Area during an animation. Confirm pane rectangles, tiling membership, tab membership, and all original shell PIDs are preserved by navigation. A stashed pane outside the main area must still fit individually even if its width or height matches the main area's dimensions.

Automated replay: `replays/title-double-click.gd`. Headless checks verify click routing, intermediate camera state, final framing, layout preservation, and interruption; assess visual smoothness from the continuous recording.
