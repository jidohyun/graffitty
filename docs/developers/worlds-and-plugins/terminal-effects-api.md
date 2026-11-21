# Shared terminal effects

Inherit the world kit to get effects automatically. Use the custom-renderer
example when replacing terminal presentation.

| Task | Section |
| --- | --- |
| Wire effects to a custom surface | [Custom renderer](#custom-world-renderer) |
| Capture a transition | [Retained state](../internals/retained-presentation.md#retained-transition-state) |
| Replace the sheet shader | [Shader contract](../internals/terminal-effects-rendering.md#shader-appearance-and-source-math) |
| Configure focus and blur | [Depth of field](../internals/terminal-effects-rendering.md#depth-of-field) |

## Use the shared world kit

The kit installs and rebinds `TerminalEffects` automatically. Set the world's
**Effects Preset**; use its `terminal_effects` property only for extra control.
Native keystrokes trigger effects. Shell output does not count as typing.

## Custom world renderer

Add one component per visible terminal presentation. Keep it under a world-owned
Node3D so removing the world removes visuals and signal connections, not shells.

```gdscript
const TerminalFX = preload("res://scenes/TerminalEffects.gd")
const FXConfig = preload("res://scenes/Effects.gd")
var effects: Node3D

func install_effects(terminal: Node, viewport: SubViewport) -> void:
    var settings = FXConfig.new()
    settings.load_config("res://presets/flat.conf") # or your plugin's preset
    effects = TerminalFX.new()
    add_child(effects)
    effects.configure(settings)
    var material = TerminalFX.create_sheet_material(viewport)
    material.set_shader_parameter("wall_shade", 0.0)
    $TerminalQuad.material_override = material
    effects.bind_terminal(terminal, material, surface_frame, presentation_frame.bind(viewport))

func presentation_frame(point: Vector2, viewport: SubViewport) -> Variant:
    # Logical terminal texture pixels, including native padding/scroll offset.
    # During a transition use the displayed live pane's transform; return null
    # when only frozen glyphs are visible. Do not use the eventual landing pose.
    return surface_frame(point / Vector2(TerminalFX.layout_size(viewport)))

func surface_frame(uv: Vector2) -> Transform3D:
    # For a centered QuadMesh facing +Z. UV origin is its top-left corner.
    var quad = $TerminalQuad
    var size: Vector2 = quad.mesh.size
    var point := Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0.0)
    return Transform3D(quad.global_basis.orthonormalized(), quad.to_global(point))
```

## Surface contract

| Responsibility | Rule |
| --- | --- |
| Material | Uses viewport texture; does not modify PTY state |
| Resize | Update `tex_size` |
| Coordinates | Logical pixels through `layout_size(viewport)`; UV mapping uses +Y up, +Z toward viewer |
| Particle size | Tune `scene.typing.particles_scale` for world units |
| Shader replacement | Preserve ripple, splash, cursor, and time uniforms |
| Rebind | Disconnects old terminal and clears trails/splash |

Cursor cells map through the real content rect; billboard materials preserve authored scale.

## Frame timing

- Default automatic mode advances idle/typing behavior.
- For a shared state machine, set `automatic = false` and call
  `advance(delta,resolved_frame)` once per frame.
- Update camera/transition geometry before `advance_cursor(dt)` in manual mode.
- `enabled = false` suppresses triggers/deformation.

Camera motion belongs to the world, not the effects component.

## Extra triggers and transitions

`typed(uv)` lets the world react to typing. The first key selects its particle
preset. `pulse(uv)` is for explicit non-key events; calling it again for a native
keystroke would double-trigger.

Transition glyph/image layers retain live ink gain, exposure, opacity, and edge
brightness. See [retained state](../internals/retained-presentation.md) and
[shader/lens details](../internals/terminal-effects-rendering.md).
