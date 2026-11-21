# World UI API

Use the shared kit to add terminal workspaces to your scenery.
The host keeps shells and session state alive; your world owns presentation.
Check `host.UI_API_VERSION` against **1** before using this contract.

## Start with the shared kit

1. Inherit `res://scenes/TerminalWorld3D.tscn`.
2. Add `res://scenes/TerminalSpace3D.tscn` destinations.
3. Position each destination's **ViewPose** camera.
4. Launch the world and check terminal input and framing.

The kit installs workspace controls, effects, and camera flights.
Follow [Author a world](authoring-a-world.md) for the complete setup.

## Choose what to customize

| Task | Read |
| --- | --- |
| Skin tabs or replace workspace controls | [World controls](world-controls-api.md) |
| Read titles, progress, or scroll state | [Session models](session-model-api.md) |
| React to battery changes | [Power events](session-model-api.md#power-events) |
| Replace terminal effects rendering | [Terminal effects](terminal-effects-api.md) |
| Inspect Flat 2D implementation and benchmarks | [Flat 2D renderer](../internals/flat-2d-renderer.md) |

Connect model signals once, then read the current snapshot. Signals do not replay
prior state. Free world-owned controls on teardown; leave host-owned sessions alive.
