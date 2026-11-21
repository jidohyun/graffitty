# Direct touch navigation

There is no center pointer. Touch titles, buttons, and node sockets directly.
Drag a title to move its pane and an output socket to an input to connect nodes.
Double-tap a title to fit. Long press opens the context action. Two-finger pinch
and pan keep the existing stationary and moving finger anchors. Releasing or
canceling touch must release all captured buttons and preserve the terminal grid.

Terminal content scrolls with one finger by default; double-tap-and-drag selects.
Use View → Terminal Touch Scrolling to switch between One Finger and Three Fingers.
The latter permits ordinary one-finger selection. In both modes, adding a second
finger cancels any pending selection and starts pinch navigation without copying.

After two-finger panning starts, lift either finger and keep moving the remaining
finger: the canvas must continue following it at unchanged zoom. Holding that
finger must not select text, drag a pane, click or open a long-press menu. Put a
second finger down again (including a new touch ID): neither contact change may
jump the camera, and two-finger pan/pinch must resume immediately using the new
contact positions. Repeat the lift/rejoin cycle, then lift both fingers and
verify an ordinary one-finger tap works again. Keep the initial pinch/three-finger
scroll guard: an uncommitted gesture must not leak movement into the workspace,
and lifting fingers after three-finger scrolling must not become panning.

Header actions use the phone's own fit scale and compact desktop spacing. Hidden actions release the entire title width. Test both
above and below the half-fit visibility threshold. The shared runtime scenario
also checks cursor shape and typing navigation; the actual APK adds native IME
and Flat 2D assertions. See `mac-trackpad` for the separate Mac intent cases.
