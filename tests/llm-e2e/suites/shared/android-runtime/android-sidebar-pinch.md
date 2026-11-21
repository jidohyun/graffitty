# Android pinch across a docked sidebar

Use the existing disposable Android-runtime client/server fixture. Open Agents
through its registered command so that it docks into the left sidebar, and move
the camera off the fitted frame, whose detent would pull a small pinch back.
Inject touch through the window, so that the platform's emulated mouse and the
dock's own input handlers take part.

1. Rest finger 0 on the sidebar content, then put finger 1 on the main area.
   Both now belong to one workspace gesture. The sidebar received exactly a
   press, a canceled emulated-mouse release and a canceled touch. Spread finger
   1 along the line through both fingers: the workspace zooms in and the point
   under the sidebar finger stays under it. Move and lift both: the sidebar
   receives nothing more.
2. Rest finger 0 on the main area past the pointer grace, then put finger 1 on
   the sidebar content. The sidebar never sees finger 1; the pinch zooms.
3. Start a pane title drag, then touch the sidebar. The drag stays held and
   keeps following its finger, while the second finger scrolls the sidebar.
4. Scroll the sidebar with finger 0, then touch the main area: the sidebar
   finger is not taken and keeps scrolling. Rest finger 0 on the sidebar for
   longer than the yield window, then touch the main area: not taken either.
   The view does not change in either case.
5. With a finger resting on the main area, touch the dock's resize edge and then
   its title: neither joins, and the canceled touches change no width, placement
   or fold state.

The original PTY survives and no contact or button remains held.

This covers injected touchscreen events on the recorded device or desktop
simulation, not physical two-hand feel. Check GE-08 in `tests/e2e/gestures.md`
for the remaining sidebars, bands, widths and landing delays.
