# Status strips share camera effects

Status strips are painted on the same sheet as their panes. Their readable size,
visibility and perimeter placement depend on deliberate zoom/pan and pane layout.
Typing zoom, follow, tilt, drift and depth of field transform the baked result.

1. In Flat, zoom out to about 45% until a resource strip appears. Confirm that
   its text is readable and its panel is outside terminal content.
2. Type with zoom and tilt enabled. The strip must move, scale and tilt with the
   sheet, including perspective and depth-of-field blur. It must not jump to a
   different pane edge, keep itself upright or toggle visibility as effects run.
3. Check that the strip's sheet transform and layout-rebuild count stay unchanged
   throughout the temporary camera motion. CPU/RAM and agent updates still work.
4. Freeze a tilted frame and compare rendered status glyphs with the depth-of-field
   compositor enabled and disabled at the identical pose. Preserve both images;
   a numeric blur setting alone does not establish that the strip was blurred.
5. Pan and change manual zoom. Placement and readable scale must update for the
   new framing, keeping terminal content clear. Main View hides overview strips.
6. Repeat zoom/pan and typing checks in Flat 2D. Tab-transition captures must use
   the strip's sheet extent and must not apply its compensating scale twice.
