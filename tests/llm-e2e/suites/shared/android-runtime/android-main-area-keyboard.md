# Android main area and keyboard

Use the production Android **Servers** entry point with an isolated server.
Keep **Fit main view to this client** enabled. A direct connection that bypasses
the server manager does not cover this regression.

1. Connect in portrait, then landscape, and verify the viewport has the requested
   orientation. The most recently active client must claim the shared main area.
   Its width and height must match the Android content surface after subtracting
   visible tab/tool bars, docked panels and keyboard space. Measure their actual
   edges independently of the production fit helpers. The floating menu does
   not reserve a full-width row. Check the server's acknowledged area, not just
   a local camera fit. Do not retain a desktop-shaped main area with letterboxing.
2. Let a second client claim a different aspect ratio. The Android client must
   follow that area while idle, then reclaim its own usable dimensions on an
   actual touch. The other client must observe that change without repeatedly
   taking ownership back. Keep the same terminal process throughout.
3. Enter Main View and put readable output at the terminal bottom. Open the
   native keyboard using the keyboard button. The main area must become shorter
   and its aspect ratio must change to match the remaining space above the IME
   and accessory key bar. Terminal rows reflow; this is not uniform camera
   shrinkage of the previous desktop rectangle. Width and font size remain
   unchanged. The bottom content moves upward and remains visible.
4. Main View must stay selected throughout keyboard opening, typing and closing.
   Sample the transition as well as the final frame: no saved overview/pan state
   may be introduced by keyboard insets. Close the keyboard and verify the full
   usable main area and row count return. Repeat twice in both orientations.
5. Start from a deliberately panned/zoomed view, open and close the keyboard, and
   verify it does not reset to Main View. Panes and content keep their place on
   screen: the keyboard covers the lower part and only the main area changes
   size. Nothing pans to reveal the cursor, and closing the keyboard restores
   the same view. In landscape, include a keyboard that hides the menu and tab
   bar. No terminal or tab is recreated.

Retain the native recording, geometry checkpoints, screenshots and process logs.
Review bottom-row readability and movement in the recording; a final screenshot
cannot prove transition continuity. Any unexpected diagnostic is a failure.
Desktop simulation covers the layout/claim logic with supplied inset heights.
Enable canvas scaling and preserve the phone's aspect ratio inside the fixed
recording canvas so both orientations exercise different logical dimensions.
Output assertions must tolerate terminal row wrapping, and command echo alone
must not satisfy them. Only an APK run certifies the native keyboard and Android
surface dimensions.
