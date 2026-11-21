# Camera motion reference

Use [CameraMotion](camera-motion.md) for a complete frame: pose plus frustum.
Apply it to scenery and ink together. The component owns no world or scene tree.

## Compose an interactive frame

| Method | Use |
| --- | --- |
| `observe(frame, delta)` | Record displayed interactive motion before a flight |
| `compose(...)` | Surface zoom/pan, cursor tilt, and containment without floating windows |
| `frame_sheet(...)` | Dolly toward workspace center and pan along sheet axes |
| `frame_pane(...)` | Same framing for a sheet filling the base frame |
| `lean(...)` | Preserve projected edges, then widen lens enough for corners |

`TerminalCameraController` resolves typing zoom, pan, tilt, shake, and drift.
Lean follows the cursor's side of the destination framing, not a gaze target;
centered cursors have no lean. `camera.tilt_limit_deg` bounds it.
Follow-pan preserves cursor space.

`TerminalWorld` maps pointer input through `sheet_point_at()` and applies the same
frame to its two cameras. The floating sheet contains all panes of the active tab.
`SpatialTerminalWorld` supplies authored routes; plugins do not replace interpolation.

## Interpolate a flight

| Quantity | Interpolation |
| --- | --- |
| Direct position | Quintic Hermite; zero endpoint acceleration |
| Lens extents | Logarithmic |
| Orientation | Shortest-arc quaternion rotation vector, with incoming angular motion |
| Routed position | Cubic segments with shared tangents; one quintic route clock |

Retargeting preserves vector, angular, and framing velocity. Derivatives are
analytic, including the rotation-vector Jacobian. A moving route retarget starts
at unit clock rate. Bad authored waypoints still need correction.

`retarget_remaining` preserves the displayed frame, derivatives, unvisited
waypoints, and remaining deadline after resize. Recalculate the destination lens first.
Navigation/scatter use elapsed render time; only physics/typing simulation steps
are capped at 50 ms.

## Choose and reverse a route

1. Prefer the authored route.
2. Otherwise use cached Dijkstra paths between destinations.
3. For a distant departure or third-destination interruption, start from the
   camera's nearest graph node.

`retarget_on_path` reverses A→B→A on the original curve, braking without leaving
it or shortening the requested deadline. Lens-only changes retain that geometry.

Optional `camera_routes.json` beside `navgraph.json` contains `routes` entries:

| Field | Meaning |
| --- | --- |
| `from`, `to` | Surface names; current poses provide endpoints |
| `points` | Intermediate world-space points |
| `bidirectional` | Defaults to true |
| `allow_wall_crossing` | Defaults to false; explicit validation exception for this route and reversal |

Curves can bow between points. The component does no collision detection;
author routes with clearance and verify interpolated paths in replay tests.

## Synchronize a transition

`TerminalWorld.tab_transition_duration()` supplies one camera/scatter deadline:
2.1 seconds by default (1.6 travel plus 0.5 settling). Custom durations,
resize, and retarget keep scatter and optical focus synchronized, without a stationary tail.

Bistro's `terrace-square-flight` replay checks forward progress, acceleration,
and 15 cm clearance for the authored Bezier crossing, including reverse travel
and repeated destinations at tabs 15–16.

## Preserve cursor framing

Use the animated cursor anchor for pivot and visibility correction. Resize must
rescale pan/cursor state to preserve normalized framing. Raw cursor jumps enter
the timed update; they must not move the camera immediately.
During catch-up, distant content may briefly leave view. Final framing reserves
cursor space, with tilt compensating perspective foreshortening.

## Verify

```sh
godot --headless --path frontends/godot/project --script tests/run.gd
```

End-to-end scenarios are in `tests/llm-e2e/README.md`.
