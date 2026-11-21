# Shared scene and interaction core

This crate owns deterministic algorithms and state. It depends on Rust data and
math libraries, not Godot, windowing, or a renderer. `glam` is re-exported so
adapters use the same vector version. Engine entities and nodes stay outside the
core; pane IDs are opaque strings and time is supplied explicitly by the caller.

| Module | Owns | Frontend supplies |
| --- | --- | --- |
| `camera_motion` | Flight clocks, interpolation, reversal, retargeting and derivatives | Displayed/destination `Frame`, elapsed time, route points |
| `typing_camera` | Framing, pan, zoom and lean math | Pane geometry, cursor and effect parameters |
| `graph_geometry` | Curves, arrows, feedback routes and endpoint deformation | Socket positions and resting route geometry |
| `navigation` | Owned graph and weighted shortest paths with Godot's equal-cost expansion order | Adjacency once on load, positions when changed, node IDs per query |
| `pane_physics` | Ordered spatial index, contacts, momentum and sleeping | Rectangles, movable/stashed membership and reachability constraint |
| `touch` | Contact ownership, grace periods, pointer/pinch/scroll recognition and fling integration | Contact events and monotonic milliseconds |

`frontends/godot/extension/src/scene` converts engine values at the boundary.
GDScript keeps input-event construction, signals, scene ownership, camera/render
updates and world loading. There is no optional native path or legacy fallback.
Another frontend can hold these core objects in its own resources/components and
apply the returned frames, rectangles and semantic actions through its renderer.
Godot uses the camera's f64 `*_seconds` APIs so converting a deadline to f32 cannot
leave a flight moving for an extra frame. Its adapters accept typed dictionaries
without changing the core's typed rectangle, placement and gesture models.

## Behavioral reference and tests

The established Godot implementation is the behavioral reference; a Rust port
must be compared against it. In particular, pane insertion order, routing ties,
gesture cancellation and camera derivatives are observable.

`frontends/godot/project/tests/fixtures/scene_core_godot.json` contains frozen
traces captured before removing the GDScript algorithms. The conformance script
covers routed reversals and resize, framing, graph curves and arrows, collision
chains, weighted paths (including ties), touch transitions and momentum. It
compares numbers with an absolute tolerance of 0.002 plus 0.002% of their reference
magnitude; discrete state and array shapes must match exactly. The fixture is test
data, not a runtime fallback. Do not regenerate it from the implementation under
test to make a failure pass.

After building the current Godot extension, run `mise run scene:test`. This runs
the Rust suite and the Godot conformance trace and rejects engine errors even if
Godot exits successfully. The regular Godot unit suite additionally tests UI
integration; rendered camera/graph and Android gesture E2E remain necessary.

## Adapter performance

`frontends/godot/project/tools/benchmark_scene_core.gd` compares the public Godot
adapters against saved pre-port GDScript. Set `GRAFFITTY_SCENE_REFERENCE` to that
source directory and `GRAFFITTY_SCENE_BENCH_OUTPUT` to an output JSON path, then
run Godot headlessly with the project path and that script. The reference directory
must include the extracted old `Navigation.gd` route implementation as well as
the camera, geometry, physics, gesture and scroll scripts.

The harness warms both implementations, alternates measurement order, excludes
setup/settling, and includes native boundary conversion and callback costs. It
uses a real authored navigation graph. These are CPU operation timings, not
whole-application frame times; compare the exact installed native build.

The local, Git-ignored `docs/developers/internals/benchmarks/scene-core-macos.json` records two runs, raw batch timings,
build details and baseline hashes. Those initial measurements showed substantial
camera/geometry and active-physics gains, but an uncached routing regression from
rebuilding the native adjacency graph on every call.

The local, Git-ignored `docs/developers/internals/benchmarks/scene-navigation-retained-macos.json` records the fix:
world-owned Rust adjacency is loaded once and route queries pass only node IDs.
Two repeated runs measure roughly 55 microseconds per uncached authored route,
versus 4.3 milliseconds in GDScript and 13.2 milliseconds in the original adapter.
Graph loading is outside the steady-state query timing. Set
`GRAFFITTY_SCENE_BENCH_CASES=world_route` to run just this workload.
