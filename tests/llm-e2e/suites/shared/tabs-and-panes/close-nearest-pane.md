# Close a pane and move to the nearest survivor

1. In both flat 3D and flat 2D, place three panes so the closest pane is not
   the first pane in layout order. Focus the pane to be closed.
2. Repeat with a zoomed-out view and a zoomed-in view.
3. Close the focused pane through its close control.
4. Keyboard focus moves to the spatially nearest visible pane. The pointer
   stays where the user left it.
5. From these manually zoomed views, the camera pans to that pane. Check the
   zoom throughout the animation, not only at the end: it must stay unchanged.
   Closing from Main View to another pane inside it keeps Main View instead,
   as covered by [Main View pane close](main-view-pane-close.md).
6. Closing must not register typing activity, start a typing zoom, tilt, or shake.
7. The surviving shells keep their PIDs. Closing the last pane of a session
   removes that session. Closing the final session also stops a private server, as
   specified in [last-session shutdown](../sessions/last-session-shutdown.md).
