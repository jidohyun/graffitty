# Backward links and manual reroutes

## Automatic backward links

Unrouted backward links adapt n8n's main-connection algorithm: activate when target X is
more than 20 pixels left of source X, join at the midpoint X and 40 px below the lower of
the two endpoint panes, use Right/Right followed by Left/Left smooth-step paths,
40-pixel handle offsets, and 16-pixel quadratic bends.

This includes Vue Flow's same-side short-span correction. Only the two endpoint pane
bounds affect the return height; intervening panes are left for manual rerouting. This
intentionally replaces n8n's fixed source Y + 130 with endpoint clearance.

Godot draws adaptively sampled polylines instead of SVG paths. Quadratic bends
are converted exactly to cubic controls before sampling with 0.05 px tolerance.
Only the horizontal same-side branch is needed for our right-output/left-input
ports. Forward links retain Blender's Bezier calculation.

## Manual reroutes

Manual reroutes replace automatic routing. They use an Graffitty-specific
continuous tangent, computed from incoming/outgoing travel directions. Shared
stems count once; each shared reroute has one tangent across its branches.
Endpoint sockets retain horizontal tangents, with handles one third of the
segment length. Drawing, hit-testing, arrows and animation use these same paths.

## Source references

Sources inspected 2026-09-30:

- n8n `getEdgeRenderData.ts`: https://github.com/n8n-io/n8n/blob/master/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/edges/utils/getEdgeRenderData.ts
- Vue Flow `getPoints` and `getBend`: https://github.com/bcakmakoglu/vue-flow/blob/master/packages/core/src/components/Edges/utils/smoothstep.ts
- Vue Flow MIT notice: `licenses/vue-flow-MIT.txt`.
