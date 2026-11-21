# Idle rendering

Idle work should stop until a relevant model, input, or rendering change wakes it.

## Workspace and terminal invalidation

- Workspace headers, status-strip placement, raster bounds and ownership links
  update on layout, model and world-projection notifications. Multiple changes
  coalesce into a deferred update; a stationary workspace does no reconciliation.
  World animation compares a small projection state, rather than scanning panes.
  Typing holds and navigation-target release use resettable one-shot timers.
- `AgentGraphOverlay.sync` reuses geometry while projected socket positions,
  endpoint bounds, edges and reroutes are unchanged. Selection and delivery
  changes redraw indicators without rebuilding wire geometry.
  `GraphWorkspaceTools.visual_segments` also caches shared reroute paths, so
  message animation can reuse geometry while moving its indicators.

### Terminal pixels

- Native `Terminal.frame_changed` fires after successful cell recording.
  `TerminalViewportUpdates` requests one viewport render for a changed frame.
  PTY processing continues when rendering sleeps. Output, blink, selection,
  IME, resizing and live configuration already invalidate native cell recording.
  Hidden viewports suppress redraw requests and request the latest frame when
  shown. Older native libraries safely fall back to continuous rendering.

### Terminal metadata

- Native `Terminal.ui_state_changed` separately invalidates title, CWD, progress,
  grid and scrolling state, including hidden terminals. `TerminalSession` reads
  that snapshot on notification; blinking does not cause state reads. Only older
  native libraries without this signal use a compatibility timer.

## Browser and queue notifications

- Chromium mailbox reads follow native filesystem notifications, and process exit
  uses a blocking OS wait on a worker. Chromium announces chromium state changes;
  there is no periodic chromium-state query. GPU/input work remains frame-driven.
  Rebuild both `frontends/godot/extension` and the native chromium host for this protocol.

### Queue inspectors

- Queue inspectors subscribe to journal changes for their selected connection.
  Bursts coalesce, hidden inspectors do no work, and status changes preserve
  existing rows. There is no refresh timer.
  Run-budget counters update through a dedicated signal. Optional connection
  stop times use one timer for the nearest deadline, which cancels pending work
  and updates the inspector even when the graph has no other activity.

## Scenery and canvas rendering

- Scenery no longer remains live merely because the window is focused.
  Camera/projection changes, dirty scenery, flights and active scene animation
  wake it. One final frame is drawn before sleeping. Ink-layer particles continue
  independently, and terminal composition remains live.

### Avoid unchanged writes

- Godot draws whenever anything was written to the rendering server, even an
  unchanged value. Camera depth of field is written only when the lens changes:
  rewriting it every frame kept worlds with physical camera attributes, such as
  Bistro, drawing at 60 fps at rest. `RenderUpdates.uniform` skips unchanged
  shader parameters for the same reason.
- The workspace canvas renders only when something changed since the previous
  draw: `RenderUpdates` samples `RenderingServer.has_changed()` at
  `frame_pre_draw`, before any work of its own. Chromium page frames update
  after that sample, beneath the canvas, so they redraw only the world.

## World plugin requirements

World plugins with procedural or shader-TIME scenery should set
`scenery_continuous = true`. Plugins changing static scenery directly should set
`_scenery_dirty = true` when it changes, and should not set unchanged material
properties on a timer: a 0.3 s streaming poll drew a frame each time. AnimationPlayer/AnimationTree and scenery
particle activity are detected automatically.

## Verify wake and sleep behavior

```sh
godot --headless --path frontends/godot/project --script tests/idle_rendering_smoke.gd
godot --headless --path frontends/godot/project --script tests/terminal_frame_events_smoke.gd
godot --headless --path frontends/godot/project --script tests/terminal_ui_events_smoke.gd
godot --headless --path frontends/godot/project --script tests/workspace_updates_smoke.gd
godot --headless --path frontends/godot/project --script tests/graph_editing_smoke.gd
godot --headless --path frontends/godot/project --script tests/graph_queue_inspector_smoke.gd
godot --headless --path frontends/godot/project --script tests/graph_queue_controls_smoke.gd -- --shell=/bin/sh
godot --headless --path frontends/godot/project --script tests/graph_deadline_smoke.gd
```

The native terminal and chromium tests require the rebuilt native library. These checks verify
invalidation and wake/sleep behavior, not GPU timings or power consumption.
