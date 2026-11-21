Open the deterministic chromium fixture in the desktop workspace. Through the actual
window input route, click its button, type in the input, drag across the paragraph
to select text, right-click, and scroll. Assert DOM results and a live GPU frame.
No gesture may call the chromium input API or DOM click/selection/scroll APIs.
Run with `--headful`: AppKit native menu tracking can block while the background
window guard suppresses its window. A hidden-window run cannot certify native
menu keyboard navigation.
The native Chrome window must remain closed. Repeat after changing pane size to
catch page-coordinate versus GPU backing-pixel mistakes.

Scroll to the document bottom. Discrete wheel ticks must leave page pixels stable.
On macOS with the Chrome-style backend, a continuous native trackpad gesture must visibly stretch the page in one direction,
without repeatedly snapping back while input continues. After release, the page
must spring back and settle at its original pixel position. Its document scroll
position must remain at the bottom. Exercise this in the normal desktop CEF path.
Include tiny fractional horizontal noise in the vertical gesture: the page must
stay visible throughout the bounce, without sliding away sideways.
The native macOS rubber-band stretch is NOT_APPLICABLE on Windows/Linux, where
Chromium disables elastic overscroll, and on the windowless Alloy
backend. Alloy cannot deliver AppKit scroll phases: CDP ends every wheel event
immediately, which restarted the spring per trackpad sample and ignored slow
motion. Alloy wheels use CEF's windowless wheel instead, whose synthetic phases
stop at the edge. Still send continuous scrolling with
fractional horizontal noise and require stable visible pixels and unchanged
bottom scroll position. Clicks, selection, typing, native menus and verified GPU
imports remain mandatory on every desktop platform.

Allow the default context menu on the input. Right-click it and check that the
Godot menu opens at the clicked point. Use actual keyboard navigation to select
Chromium's Select All command and verify the input selection. A page handler that
prevents the default menu must continue to suppress it.
