Open three tabs with distinct visible terminal content. In Flat 2D, Flat 3D and
Bistro, close the selected middle tab with the default Push/Pull transition. Its
captured panes must depart while the surviving tab arrives, without an instant cut.
Closing an inactive tab must leave the selected pane and camera undisturbed.

In Flat 2D and Flat 3D, select Push/Pull under View > Tab Transition.
Switch to a larger displayed tab number: outgoing panes enlarge, defocus and
fade as the incoming panes approach. Switch backward: the dolly reverses.
This effect completes in about 420 ms and keeps panes intact. Repeat after
reordering tabs, close the selected tab, and reverse a switch before it finishes.
The destination must return to live content. Closed terminals must be released
while their independent drawing state still animates; retained presentations
must be released once both active and interrupted animations finish.

With typing DOF active in Flat 3D, press Ctrl+D at an empty shell prompt in the
last tab. As its predecessor arrives, the departing text must retain its focus
on the first animation frame and defocus continuously with its own depth. The
nearly transparent incoming pane must not suddenly blur the outgoing terminal.
Normal live-terminal DOF must resume after landing.

Use multiple panes at different positions, with different saved pan and zoom
on the two tabs. All panes, frames and decorations must share one quintic
smoothstep clock from start to finish. Push and pull use reciprocal zoom ranges;
incoming and outgoing panes crossfade over the same interval. Saved camera
framing must not add a second acceleration or a last-moment settling movement.
