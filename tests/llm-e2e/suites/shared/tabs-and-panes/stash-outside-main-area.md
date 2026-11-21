# Stash windows outside the main area

Launch `mise run dev -- --shell=/bin/sh`, open Bistro (night), and record each stage with screenshots. Report PASS, FAIL, or BLOCKED. An invisible pane with correct model coordinates is a failure.

## Stash in Bistro

In one tab open two terminal panes, print unique markers and shell PIDs, and enable **Tile**. Pinch out. A border must show the main area; its aspect ratio follows the Graffitty window rather than the world wall. Drag one pane by its title bar entirely to the right of the border and release. It must remain visibly rendered and draggable there, retain its shell, and remain in the same tab. The remaining pane must fill the main area. The stash is not tiled.

## Return and retrieve

Choose **View → Fit to Main Area** to return to normal framing. The stash must stay outside, not snap back. Resize the application and toggle tiling off and on: the stash's position and size must not change. Pinch out, type in the stashed pane, and drag it back into the main area beside the other pane. It must rejoin tiling while retaining its PID and output. Repeat to the left and above the main area, including negative sheet coordinates. Press Escape during a drag: membership and placement must be restored.

## Switch worlds

Repeat or preserve a stash while switching to Flat and back to Bistro (night), loaded as the installed `bistro` world. Main and stashed panes must remain visible in Overview and retain their sessions. Returning to Main must work in each world. No authored wall boundary may clamp a stash. Confirm tabs and desktop windows were not accidentally created.
