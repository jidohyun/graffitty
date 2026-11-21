# Terminal ink rendering

Terminal ink and scenery use separate depth-of-field passes.

## Visible behavior

The focal plane stays sharp. Increase `dof_blur_amount` to blur out-of-focus ink;
zero disables it. Scenery keeps its own depth of field.

## Blur model

The dedicated ink camera now applies **two screen-space, 17-tap Gaussian passes**
after transparent geometry, filtering linear premultiplied RGB and alpha together.
Depth discontinuities reject unrelated samples. Blur is normalized to the visible
sheet's depth variation, with a minimum range to avoid amplifying tiny tilts, and
capped at 24 screen pixels. In-focus pixels remain sharp. 

The existing `[scene.camera] dof_blur_amount` controls strength: the default
`0.125` corresponds to an 8-pixel radius at the sheet's depth-range limit;
`0.25` requests 16 pixels. Zero disables it. The scenery keeps its native depth
of field. During full scene flights, or without a rendering device, the existing
material filtering remains the fallback, now using the corrected depth scale.
This is not a solution for arbitrary layers of overlapping transparency.

For user settings, see [Terminal appearance](../../customize/configuration-appearance.md).
