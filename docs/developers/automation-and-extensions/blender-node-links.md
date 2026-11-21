# Blender node-link geometry port

Graffitty uses Blender's handle/tangent calculations with its own terminal
permissions, route policy, and Godot renderer.

## Source and scope

Pinned Blender revision: `a5d2d415d03098df760257ee3931001223dfd32a`.
The translated code retains [GPL-2.0-or-later](../../../licenses/Blender-GPL-2.0.txt).

Sources:

- [drawnode.cc](https://github.com/blender/blender/blob/a5d2d415d03098df760257ee3931001223dfd32a/source/blender/editors/space_node/drawnode.cc):
  `calculate_inner_link_bezier_points`, `LINK_RESOL`.
- [gpu_shader_nodelink.bsl.hh](https://github.com/blender/blender/blob/a5d2d415d03098df760257ee3931001223dfd32a/source/blender/gpu/shaders/gpu_shader_nodelink.bsl.hh):
  cubic position, analytic tangent, and zero-tangent fallback.
- [userdef_default_theme.c](https://github.com/blender/blender/blob/a5d2d415d03098df760257ee3931001223dfd32a/release/datafiles/userdef/userdef_default_theme.c):
  shipped theme curvature of 4 (RNA's property default is separately 5).



| Geometry rule | Value |
| --- | --- |
| Display subdivision | Adaptive de Casteljau; 0.2 screen-pixel tolerance, depth 12 |
| Arrow lookup / gesture intersection | 24 uniform / 25 CPU samples |
| Coincident endpoints | Zero tangent, no arrow |
| Arrow placement | Half arc length |

Safe division, zero-curvature, slope clamp, handle offsets, and tangent fallback
are retained. GPU strip/gradient/outline/dash shaders, socket layout, and
Blender's full operator ecosystem are not ported.
Backward links use [Graffitty routing](n8n-link-routing.md); manual reroutes replace it.

## Graph interaction source audit

| Upstream implementation | Graffitty implementation |
| --- | --- |
| `node_add.cc`: `link_path_intersection`, `add_reroute_exec` | 25 CPU curve samples, first intersection per segment, 256-point gesture cap; group by output socket, mean insertion position. Shared stems are stored and drawn once. |
| `node_relationships.cc`: `cut_links_exec`, `mute_links_exec` | Collect intersections before changes; one undo operation. Shared-stem mute affects downstream terminal edges; aggregate branch mute determines upstream stem state. |
| `node_relationships.cc`: `node_link_init`, `pick_input_link_by_link_intersect` | Input link dragging, remembered multi-input candidate selected by squared-distance threshold 12.5, detach after leaving socket; Ctrl-output batch detach/reconnect; cancellation and empty-space disconnect. |
| `node_view.cc`: `space_node_view_flag` | Aspect-dependent bounds expansion followed by 1.1 scaling. |
| `interface/view2d/view2d_ops.cc`: `smooth_view_rect_to_fac`, `view2d_smoothview_invoke` | Distance/scale duration factor and cubic smoothstep rectangle interpolation; Godot Tween supplies the clock, using a 250 ms base duration. |
| `node_edit.cc`: `node_link_dim_factor` | Offscreen endpoint distance controls gesture eligibility; selection dimming does not disable editing. |
| `blender_default.py`: node-editor keymap | Shift-RMB reroute, Ctrl-RMB cut, Ctrl-Alt-RMB mute, view commands use toolbar buttons to preserve terminal keyboard input. |

### Necessary application differences

- Permission edges own delivery. Reroutes add no agents, rights, hops, or queues.
- Detach stays visual until drop; cancelled gestures must not cancel queued work.
- Batch reconnect validates all destinations; permission conflicts are rejected.
- Mute cancels pending work. Undo restores wiring, not cancelled messages.
- Tiling/physics remain workspace-owned; reroutes use canvas coordinates.

## Link occlusion and draw order

Established wires, arrows, and message indicators render before panes in the
workspace canvas. Panes occlude them. Sockets, tooltips, and active previews
remain in the screen overlay. Blender's handle calculation does no obstacle routing.

Right-click a reroute to remove it while preserving connections; Shift-click
selects several. Cmd-Z / Cmd-Shift-Z undo/redo except in native text fields;
Escape cancels gestures. Pointer mappings follow Blender. Terminal keyboard
bindings remain available; no graph toolbar is installed.

## Verification

`tests/graph/generate_blender_link_reference.py /path/to/blender` compiles the pinned
C++ function/shader expressions: 28 cases × 5 evaluations, curvatures 0/1/4/10.
The fixture checks forward/backward/vertical/horizontal/short/coincident geometry.

```sh
godot --headless --path frontends/godot/project --script tests/run.gd -- graph_link_geometry
godot --path frontends/godot/project --script tests/graph_link_animation_smoke.gd
```

`tests/graph_editing_smoke.gd` checks real input, shared fan-out, cut/mute,
reroute insertion, input picking, batch reconnect, cancellation, and undo.
Only the geometry fixture is compiled from Blender source.
