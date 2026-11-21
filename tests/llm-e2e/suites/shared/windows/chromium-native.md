# Windows native chromium ownership

Use an isolated owner and Windows D3D12 frontend at the desktop display scaling.
Keep real chromium PID and page markers; never attach a personal Chrome profile.

## Exercise native chromium tabs

Require a confirmed native GPU channel and imported frames. Use the chromium's
plus button to create three tabs, assign each a distinct page marker and color,
select the first tab and verify its original state. Close the first tab through
its close button. Select the last surviving tab and verify its marker. Chromium
control must survive closure of the original page. Exercise Chrome page zoom.

## Open and close native presentation twice

Click the external presentation control. Require one visible owned Chrome window
with keyboard focus, the same chromium PID and the selected page's original marker.
Capture that native window, then send its standard system-close action. Require
return to the embedded pane, increasing GPU imports and unchanged page state.
Repeat to verify foreground activation on reopening. Review both native captures
and the replay movie; native windows are not captured by Godot Movie Maker.
