# Graph editing and transport contracts

Validate graph wiring, reroutes, mute/cut, undo/redo, direction-aware curves, delivery animations and graph read permissions.

Run from the repository root:

```sh
python3 tests/agents/test_agent_e2e.py --case graph
```

## Graph editing

Run graph_editing_smoke.gd. Require create/reconnect/preview, reroute, cut/mute, undo/redo, selection, permission changes, geometry cache and terminal-key preservation checks to pass.

## Wire geometry and animation

Run graph_link_geometry_smoke.gd and graph_link_animation_smoke.gd. Check both directions, reroute tangents, feedback clearance and the queued/sent/failed animation lifecycle. A headless run proves assertions, not visual smoothness.

Run graph_compact_ports_smoke.gd with a large UI font: socket resize callbacks
must settle without exhausting the message queue. A newly pressed dashed output
with zero drag distance must draw without an empty-multiline error. On touch UI,
drag a compact output bundle to an input, choose the named output from the shared
touch menu, and verify the resulting edge uses that exact port.
Run it again with `-- --touch-controls`. A projected 200px pane at quarter zoom
must expose five separate outputs with non-overlapping 44px touch targets; mouse
targets keep at least 28px spacing. An 80px pane must compact. Verify wire endpoints,
unchanged graph data, and route-cache reuse as the expanded ports spread during zoom.

## Graph authority

Run agent_graph_smoke.gd against the real app. Check read permissions, file references, completion deduplication and disconnect/reconnect. These transport contract fixtures are deterministic and do not claim to be real model runs.

## Evidence and result

Retain report.json, replay.log and evidence.json in the private run directory. Report PASS, FAIL or BLOCKED. Authentication, model access, unavailable sockets or denied process inspection are BLOCKED, never PASS. A receipt without an assistant response does not prove delivery completion. Live visual quality requires a separate windowed recording.
