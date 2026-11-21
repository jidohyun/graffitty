# Author a world

Start with the shared 3D kit. It supplies terminals, input, tabs, tiling, effects,
and camera movement; you add the scenery and viewpoints.

## Build the scene

1. Inherit `res://scenes/TerminalWorld3D.tscn` and save it under `res://worlds/your-world/`.
2. Add scenery and lights as ordinary Godot nodes.
3. Move or duplicate `TerminalSpace3D.tscn` instances to create terminal destinations.
4. Adjust each destination's **ViewPose** camera and `visit_order`.
5. Point `plugin.json` at your scene, [pack it](publishing-a-world.md), and
   launch the pack:

   ```sh
   mise run dev -- --plugin=/path/to/your-world.pck
   ```

   Graffitty loads worlds only from packs. Edit the scene in the Godot editor;
   rebuild the pack to run your changes.

Use `tests/fixtures/StarterWorld.tscn` for a two-destination example.
Live shells and layouts survive world switches.

## The shape of a world scene

```text
MyWorld                 TerminalWorld3D
├── Scenery             Node3D
└── Spaces              Node3D
    ├── Destination0    TerminalSpace3D
    │   └── ViewPose    Camera3D
    └── Destination1    TerminalSpace3D
        └── ViewPose    Camera3D
```

Prefer a scene entry in the manifest:

```json
{"api": 1, "id": "my-world", "entry": "res://worlds/your-world/world.tscn"}
```

A world can live in its own repository. Its scenes still use `res://worlds/<id>/`
paths and the shared kit, so its Godot steps run in a Graffitty checkout's
project. While those steps run, the world's pipeline links the repository at
`frontends/godot/project/worlds/<id>` (ignored by Git) and removes the link
afterwards. Bistro works this way:

```sh
python3 pipeline.py pack --graffitty <checkout>             # dist/bistro.pck, bistro.json
python3 pipeline.py run --graffitty <checkout> -- --editor  # the editor, with Bistro linked
```

Edit its entry, `world.tscn`; it loads the baked scenery from
`generated/preview/`. Graffitty's own tests load Bistro by id, from the
installed pack.

## Where a terminal goes

A `TerminalSurface3D` is a place for a tab. Move and rotate it like other geometry.

| Property | Purpose |
| --- | --- |
| `canvas` | Screen size and aspect ratio in world units |
| `visit_order` | Destination order; ties follow scene-tree order |
| `surface_id` | Stable name; defaults to the node name |
| `surface_lift` | Offset from backing geometry to avoid z-fighting; default `0.06` |

Tabs occupy destinations in order. Extra tabs share destinations after all places
are used. Each surface needs a `Camera3D` child such as **ViewPose**.
Its `fov` is horizontal under `KEEP_WIDTH`; use the editor's Preview to check framing.

The terminal mesh stays a flat quad. The sheet shader handles curvature and ripple.

## Test and package

Launch your pack, check framing at several window sizes, then follow
[Publishing a world](publishing-a-world.md). Packs contain authored assets;
the shared kit ships with the host.

See [scripted scene serialization](scene-serialization.md).

## Optional customization

Finish and test the basic scene before changing these hooks.

### Camera movement and optional replacements

Straight flights between ViewPose cameras work automatically.
For a route around scenery, add a `Path3D` and assign it as the destination's
**Approach Path**. Leave obstacle clearance; routes do not perform collision avoidance.

| Setting | Replace it to customize… |
| --- | --- |
| **Terminal Space Scene** | Tabs, buttons, status strip, and workspace UI |
| **Effects Preset** | The world's effect defaults |
| `WorldEnvironment` | Lighting and environment; otherwise the kit provides defaults |
| `_navigation_route()` | Procedural camera routes |

Use [CameraMotion](camera-motion.md) rather than a second camera controller.
For a custom renderer, see [World UI API](world-ui-api.md) and
[plugin design](design-plugins.md).

### World-owned settings

Read your `[worlds.<id>]` table from `client.toml`:

```gdscript
const WorldConfig := preload("res://graffitty/world_config.gd")

func _ready() -> void:
    var mine: Dictionary = WorldConfig.table("my-world")
```

The world owns its schema and defaults. Override `read_settings(user)` to use
`WorldConfig.load_settings(settings_script, user, ["my-world"])` for typed validation.
Unknown keys, invalid types, and failed validation skip that table with a warning.

Tables apply in order; later tables override only their supplied keys.

Users can change a setting from the menu with a
[`SetWorldSetting` entry](../../customize/world-settings.md#change-a-world-setting-from-the-menu).
The host sets and validates the value, then calls `settings_changed(setting)` on your
world scene if it has one. Implement it to apply settings live:

```gdscript
func settings_changed(setting: String) -> void:
    if setting.begins_with("weather."): apply_weather()
```

Without it, a changed setting takes effect the next time the world loads.
New windows load changes without changing existing windows.

| World | Tables, in order |
| --- | --- |
| Bistro | `[worlds.bistro]` |

Bistro uses the shared `WorldSettings.gd`. Keep scenery and lighting in authored nodes;
use code for navigation data, camera interpolation, and computed settings.
