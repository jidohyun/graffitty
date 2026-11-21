# Retained graph rendering

Graph routing is independent of the camera. `AgentGraphOverlay` stores routes in sheet
coordinates; `GraphWireLayer` paints them into the same retained canvas as the panes.
Panning moves that canvas without rebuilding its wire commands.

Zooming and perspective also move the canvas; below each wire's minimum screen width,
they refresh its stroke and pattern spacing while retaining its route and unchanged
color texture. Screen projections still update socket hit boxes, reroute handles, hit
testing and message markers.

Sampled paths are projected lazily for picking or active markers, not for every edge on
every camera update.

## Invalidation rules

### Markers

- Queue blinks and delivery pulses have a separate marker layer. Their animation
  must not invalidate static wire paint.

### Pane movement

- Pane movement invalidates incident route-cache entries and return-lane peers
  sharing the affected input. Unrelated routes reuse their sampled geometry.
  Explicit reroute geometry also depends on neighboring shared stems. Each wire
  has a retained canvas item; unchanged wires keep their paint commands too,
  rather than merely caching CPU routing while repainting the entire graph.

### Geometry

- Curve sampling, endpoint deformation, return-lane ordering and dash generation
  are portable Rust in `crates/scene-core/src/graph_geometry.rs`; Godot adapts the
  results. Dashes submit a multiline batch, not a draw call per dash.
  Socket motion deforms a cached route by traveled distance, not sampled-point
  index. Adaptive sampling puts many points in a corner and few on a straight
  run; index-based deformation creates hooks when zoom spreads the ports.
  The distance blend preserves sockets and remains independent of sample density.

### Ownership and transitions

- Ownership links retain sheet geometry too. An explicit graph connection in
  either direction suppresses the redundant ownership wire, not ownership data.
- Transition captures include both retained wires and the current marker frame.

## Verify retained work

`tests/graph_retained_geometry_smoke.gd` uses 14 nodes and 42 edges to check camera
invariance, marker-only repaint and partial route invalidation. Its timing output
is diagnostic; tests assert work counts rather than hardware-dependent FPS.
`tests/ownership_links_smoke.gd` checks suppression and restoration without
mutating ownership. Existing graph editing and message-animation tests cover
interaction and lifecycle behavior.

## Process discovery is separate from graph rendering

Recurring agent/app discovery no longer executes `ps` on macOS, Linux or Android.
`apps/cli/src/process_inventory.rs` uses libproc on macOS and `/proc` on Linux /
Android, retaining UTC start-time identity checks. Windows retains its native process
adapter. This is not a claim that all discovery is event-driven: the server's bounded
discovery timers still exist.

They also detect exec within an unchanged foreground process group and provider session
registration after launch. Removing those timers requires equivalent process and
provider-file notifications, not just dropping the refresh and leaving stale identities.

Resource Monitor is separate: `crates/platform/resource-monitor` has its own shared
sampling worker and native backends; it does not use this CLI process inventory.

Test servers must be shut down after replay tests. Abandoned servers duplicate
inventory work even when no frontend is attached. Profiling should isolate these
from the live server, use separate log files, and distinguish sampled stacks from
measured callback timings. A stripped stack sample cannot attribute engine work
to a particular GDScript callback or prove GPU allocation frequency.
