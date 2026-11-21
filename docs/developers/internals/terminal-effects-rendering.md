# Terminal effects rendering

Shader, lens, and verification details for custom renderer work. Start with [the effects API](../worlds-and-plugins/terminal-effects-api.md) to bind a surface.

## Shader appearance and source math

`terminal_particles.gdshader` reproduces an analytic spark center, tail, fork and glow
in a native Godot spatial shader. `TerminalParticles.gd` uses Godot MultiMesh for
sparks, with pixel-based speed, gravity, drag, lifetimes, depth velocity, cooling,
distance attenuation and .045s streak exposure. New bursts append to a bounded pool
instead of restarting previous bursts.

Spark tint starts with the terminal's current SGR write color and follows the
originating glyph for 300 ms as shell echo/highlighting arrives. `cell_glyphs()` exposes
resolved `foreground` colors (including inverse); `get_write_color()` exposes the
current pen.

Thickness scales by cell height / 26, then uses the sheet's source-pixel world scale, so
font changes and camera zoom affect sparks and text together. White glyphs legitimately
produce near-white sparks. Other presets use GPUParticles3D; dots and trails have soft
round masks.

### Sheet deformation

`terminal_sheet.gdshader` uses a source-pixel ripple wavelength,
exponential falloff, degree amplitude and radian phase, plus eight independent
traveling sine/Gaussian splash packets. The depth formulas from `camera.c` are
adapted through an inverse-perspective UV mapping,
not a tessellated mesh. `SheetMath.gd` supplies corresponding CPU reference math.

## Depth of field

DoF uses a shared normalized thin-lens circle-of-confusion model:

```gdscript
effects.update_lens(camera, cursor_world_position, zoom)
```

The lens never changes camera projection or focal length. Physical camera
attributes only carry world-owned exposure calibration (f/16, 1/125 s, ISO 100);
blur strength is `dof_blur_amount`, set on Godot's bokeh pass directly.

The world also calls `effects.update_lens(camera, focus, zoom)`. `[scene.camera]
dof_blur_amount = 0.125` uses Godot's `CameraAttributesPractical` unit: 1.0 is a
64-pixel radius at infinity (8 px here), multiplied by zoom. The depth curve is `abs(1 -
focus_depth / fragment_depth)`. Godot's native bokeh pass handles opaque scenery;
alpha-aware shader sampling handles terminal ink and analytic spark blur.

The sheet writes its own depth in the transparent pass (`depth_draw_always`), discarding
fully transparent pixels. This keeps scene DoF from using the sky or masonry depth
behind text. Focus follows the live cursor after grid-to-texture mapping, including
padding/insets.

### Scenery and ink passes

The shared world kit renders terminal sheets, transition pieces and sparks in a separate
transparent viewport with the same off-axis frustum and pose, above scenery. This avoids
geometry occlusion and a second scenery-depth blur on ink. Native DoF runs only on
scenery.

Forward+ ink uses a screen-space, depth-aware Gaussian; other renderers use a fragment
kernel measured in screen pixels. These kernels approximate the shared CoC; they are not
identical bokeh filters or a full optical simulation. Chrome composites above the ink
pass.

This deliberately normalizes away physical world scale, which otherwise made blur nearly
invisible in large scenes. Zero strength disables all shared lens blur. The focal plane
stays sharp; transparent-window mode supports sheet/particle blur but cannot blur the
macOS desktop behind the window.

### Transition passes

During Push/Pull, Forward+ renders each retained workspace in a separate transparent
viewport using the same screen-space lens as live ink, then alpha composites the
results. Independent depth buffers prevent a nearly transparent arriving pane from
abruptly defocusing the departing text.

The transition keeps at most four passes (two retiring workspaces and the current pair)
and releases them after landing. These passes redraw retained terminal state at the
current resolution; they do not read back or animate screenshots. Other renderers keep
the per-pane fragment lens. The lens stays active throughout the transition.


## Tests

The fast rules in `tests/unit/` run with
`godot --headless --path frontends/godot/project --script tests/run.gd`; end-to-end cases are in
`tests/llm-e2e/README.md`.

Rendered smoke coverage includes `tests/retained_handoff_smoke.gd` (Flat 2D,
Flat 3D and authored-world parity, source-world destruction and target release),
`tests/chromium_retained_toolbar_smoke.gd` (toolbar pixel parity, source teardown
and interrupted exits), and `tests/tab_window_session_smoke.gd` (real detach,
input, merge and native-window identity). These paths are relative to the Godot
project and require GPU rendering.
