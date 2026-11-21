# Select tabs beyond the world's authored positions

Open Bistro, then create at least 26 tabs (or three more than the
world's authored positions). Narrow the window until the tab strip scrolls.

- Tabs cycle through the authored positions in order: the first tab beyond the
  last Bistro position returns to position 1, then position 2, and so on.
- Scroll to tabs 24, 25 and 26 and select each. The clicked tab retains its
  selection, terminal focus and selected appearance while owner updates arrive.
  There is no intermediate selection of tab 1 or another tab.
- Selection does not resize or slide tab buttons. Only the scroll offset may
  change to reveal the selected tab. New, closed and reordered tabs may animate.
- Scroll back and select earlier tabs; their positions and sessions remain intact.

Godot: tabs exchange content on the wall in view and do not travel between
places, so which tab holds which position follows the selection. Every tab must
stand at an authored position, tabs beyond the last position must share the
positions in turn, and each selected tab must appear on the wall already in view.

The Godot replay checks every tab's world position and records tab geometry and
selection changes during actual press/release input against a private server.
