Open two workspace tabs. In the second, open a Chromium pane on about:blank
and focus its address bar. Switch away and back with Scatter,
then Push/Pull. Both directions must animate and keep browser focus when
returning. Repeat in Flat 2D and Flat 3D.

Use the browser's + button repeatedly until ten tabs overflow the pane. The +
button must remain visible and clickable at the right of the visible tab row.
Scroll the tabs to either end and create another tab. Closing and adding should
keep the + button outside the clipped row while moving smoothly with tabs that
fit. Verify the page count against Chromium's reported state.

With floating pane physics enabled, place the owning terminal against its
Chromium pane. The placed terminal must stay fixed while the browser yields.
Repeat with the browser as the placed pane: the terminal must yield instead.
Their ownership link must not pin both panes. Header and browser content move
together, without resizing or recreating the browser or its page tabs.
