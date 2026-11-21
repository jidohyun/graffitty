Run the `tabs-and-panes/pane-repulsion` replay without native desktop input. Inspect every retained image; telemetry alone cannot prove visible pane motion. Its equivalent control
is **View → Floating Pane Physics**. On Windows the replay captures the actual
native menu in `native-view-menu.png` and its checked state in `native-menu.json`;
an owned-process helper dismisses the native modal loop. Review the timed motion
PNGs, typing-pinned/resumed frames and tiled frame alongside the movie. Input
must pin the active pane even when visual typing effects are disabled.

The disabled frame must show two close floating terminals. The timed repulsion frames must keep the latest placed terminal still while its neighbour moves away smoothly. The distant terminal must not move. Verify the terminal header and content move together and that neither PTY grid nor process changes.

Typing temporarily pins the active pane, and movement resumes when typing ends. Tiled leaves remain still. Verify the actual Effects dialog contains a readable Floating pane physics checkbox with the current tab's disabled state. A new tab must independently default to enabled. Do not mistake a disabled geometry-isolation fixture for evidence of the physics feature itself.

Retain the first failed run, its trace, motion series and screenshots. Report clipping, content squeeze, sudden jumps, unexpected movement or unreadable controls as failures even if assertions pass.
