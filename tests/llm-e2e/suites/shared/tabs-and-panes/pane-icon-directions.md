# Pane creation icon directions

Test both tiled and floating workspaces:

- Left-click the new-pane-right icon: create exactly one pane to the right.
- Right-click the same icon: create exactly one pane to the left.
- Left-click the new-pane-below icon: create exactly one pane below.
- Right-click the same icon: create exactly one pane above.

With touch controls, a tap matches left-click and press-and-hold matches
right-click. Holding must create exactly one pane (left or above), never the
tap's right or below pane as well when the finger lifts.

The right-click action must not also open the title context menu. Keep the
workspace's existing tiling mode. Remote clients send the requested side to the
GUI server, or use it in their local layout for a headless server.
