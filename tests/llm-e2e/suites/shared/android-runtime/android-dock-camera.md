# Dock-aware camera and cursor

Use the existing disposable Android-runtime client/server fixture. Open Agents
and Sessions through registered actions (retain Agents if already open by default), open Resource Monitor, and commit them through the production
dock layout. The separate android-list-docking case covers drag routing.

A real PTY program positions a steady cursor at opposite terminal corners.
With a left sidebar, right sidebar, two sidebars, resized sidebars, top/bottom
Resource Monitor docks alone and together with sidebars, and then no docks, test
1.15×/2× typing zoom (select typing zoom mode explicitly; adaptive framing has
its own content-dependent target). Verify both vertical reservations and pointer-region exclusion.
Also grow/shrink each horizontal dock while zoomed and check cursor containment on
every sampled frame. Test fixed-geometry navigation/cursor coordinates separately:
dock resizing legitimately reflows the PTY grid and refits its layout. Check the entire projected cursor cell against
the unobstructed content rectangle and inspect actual framebuffer pixels, not
only camera state. On a phone, two sidebars can leave the pane narrower than
a typical grid; the server grid must shrink to fit it (down to two columns)
so the cursor column is never drawn past the pane edge. Cursor-follow must not
rewrite saved navigation. At manual
zoom, pinch/pan must preserve the finger's canvas anchor with the same insets.

Run simulated coverage and device coverage separately. Record device evidence
outside the repository; do not operate on the user's live terminals. Repeat on
phone and foldable, with IME visible and after rotation before claiming those
additional acceptance cases. See UI-09 and GE-04 in tests/e2e.

Close the default Status Line to isolate each dock reservation. After committing a horizontal drop, set its row to 120 pixels: the drop itself installs the floating panel height.

The raw PTY cursor fixture redraws on SIGWINCH as well as key input, keeping the requested corner when a dock reflows the grid.
