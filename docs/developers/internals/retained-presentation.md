# Retained presentation

Retain drawing state so transitions can outlive terminals and source worlds.
A retained view redraws commands at a new density rather than permanently
flattening terminal text into a screenshot.

## Retained transition state

| Transition | Source | Arrival |
| --- | --- | --- |
| Push/Pull | Live until retirement; freeze on close/interruption | Live texture |
| Fly away | Frozen glyph state | Live zooming terminal texture |
| Fly away and in | Frozen glyph state | Frozen glyph state |

Normal live content resumes at landing. Hidden panes then stop rendering/streaming.

### Prepare and release

1. Hold subscriptions/rendering while departing layers move.
2. Prepare the destination's full geometry, including outside the camera crop.
3. Wait for acknowledged layout, matching grid, and painted frames; no fixed quiet delay.
4. At landing, restore normal cropping and keep assembled imagery until repaint/GPU draw completes.
5. Release holds with their moving layers.

Layout and acknowledgement may arrive in either order. Continue once topology
reaches the acknowledged revision. A snapshot is not ready while repaint is pending.

### Native drawing state

`Terminal.capture_render_state()` retains glyph runs, font references, colors,
selection, cursor, IME, decoration, scroll transforms, and actual image references.
`TerminalRenderSnapshot.create_view(density)` creates a renderer without a shell
or input. Live and retained views share paint operations.

`RetainedViewport.gd` serves CellShatter/TabTransition2D and copied chrome.
Same-frame layers share immutable state and raster targets. Growing projections
request quarter-density steps; logical metrics/UVs stay fixed. Pixel budgets
still apply. Stable targets do no extra rendering; sources may be destroyed.

### Image capture audit

| Area | Current use | Follow-up |
| --- | --- | --- |
| Push/Pull terminal tab transitions | Live outgoing and incoming textures; retained state on close or interrupted retirement | Live rendering and subscriptions end with the moving layer. |
| Scatter terminal transitions | Native drawing state with independent ownership and adaptive raster density | Implemented; `CellShatter.build_cells()` also uses semantic cell occupancy instead of reading pixels. |
| Pane headers, frames, borders, monitor and graph decorations | Copied UI/drawing state in retained viewports | Implemented; resized targets redraw the copied state. |
| `TabDragPreview.retain_presentation()` | Independent scene nodes, terminal drawing commands, camera/lens state and copied UI | Implemented; viewport samplers are rebound to retained targets, and the preview owns them until handoff or cancellation. |
| `ChromiumPanel._retire_panel()` | Twelve normalized toolbar slices sample one retained control view | Implemented; no window readback or image crop, and resizing redraws native toolbar text. |
| `ChromiumSurface3D._retire_surface()` | Each outgoing surface owns a retained toolbar view | Implemented; its raster density follows projected size and its targets are freed with the outgoing surface. |
| Scenery idle rendering and `Main._capture_frozen_frame()` | Reuses a rendered 3D background while its scene/camera is unchanged | Intentional render cache; the scene remains available for the next redraw. |

### Preview ownership

`RetainedPresentation.gd` copies presentation nodes without session/input scripts.
Immutable meshes/fonts/media are shared; mutable materials, instance buffers,
viewport bindings, and explicit drawing commands are copied.
Retain off-axis camera convention and DOF overrides, not just ordinary properties.
The preview owns its copied 3D world until handoff; the one-tab header stays above
it and the destination reuses the native window.

Browser/video frames, inline images, wallpapers, icon raster caches, and blur
buffers remain pixel assets/render outputs. They are distinct from retained text/UI commands.
