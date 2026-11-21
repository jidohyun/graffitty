# Overview pane resources

1. Open View → World → Bistro. Create three terminal panes in one tab.
2. At normal zoom, confirm terminal backdrops are 85% opaque and text is readable against the scenery.
3. Zoom out until resource monitor and other toolbar buttons disappear.
4. Every visible pane has its original unchanged header, with a separate narrow multiline screen-space panel above it: stable pane UID (`%N`), process-tree CPU percentage and RAM (M/G, binary units). The pane UID is on the first line; CPU and RAM occupy separate rows with aligned icon and value columns. The panel does not repeat the title. A chip SVG and a memory-module SVG replace the CPU and RAM words. Panels prefer above the top-left corner, then slide along the pane edges to stay visible. They never cover any terminal content, headers, or other stats, and have no connector lines. If no free on-screen edge space exists, hide the stats rather than cover stdout. Pan the panes near the top edge and verify the stats move beside or below them. They do not intercept clicks.
5. Wait for live samples. Each UID identifies its own pane, including unfocused panes. Run a short CPU workload in one shell and confirm that pane's CPU reading updates. Pending/unavailable/paused data shows a dash, not a fabricated zero.
6. Zoom back in. The captions disappear and full toolbar controls return. Repeat zooming out; captions return with current stats. Shells and pane sizes are preserved.
