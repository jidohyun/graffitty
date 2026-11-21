# World plugin design

Use the shared world kit to present terminals in a custom scene. Start with
[Authoring a world](authoring-a-world.md) for a working setup.

## Who owns what

| Layer | Responsibility |
| --- | --- |
| Host | PTYs, sessions, input, IME, configuration, windows, plugin loading |
| Shared kit | Terminal surfaces, framing, camera movement, effects, and UI bindings |
| World plugin | Scenery, lighting, viewpoints, and custom presentation |

Worlds can switch without restarting shells. The built-in Flat worlds use the same
interface as world plugins.

## Extend the kit

Use a scene rooted in `TerminalWorld3D.gd` with `TerminalSpace3D` destinations.
Override only the behavior your world needs:

```gdscript
extends "res://scenes/TerminalWorld3D.gd"
const WorldConfig := preload("res://graffitty/world_config.gd")

func read_settings(user: TerminalConfig) -> RefCounted:
    return WorldConfig.load_settings(settings_script, user, ["my-world"])

func configure_terminal(user: TerminalConfig) -> TerminalConfig:
    return super.configure_terminal(user)

func configure_effects(effects: RefCounted) -> void:
    super.configure_effects(effects)
```

Override `_navigation_route()` for custom routes. Use the shared
[CameraMotion](camera-motion.md) component for flights and framing.

## Preserve terminal behavior

If you replace the renderer or UI, your implementation must still handle these:

| Requirement | Shared implementation |
| --- | --- |
| Window-relative grid size and aspect | `_terminal_content_rect()`, `_canvas_span_in_frame()` |
| Native-resolution text and font scaling | `_sync_terminal_viewport_size()`, `_apply_terminal_font_scale()` |
| Premultiplied texture alpha | `terminal_sheet_common.gdshaderinc` |
| Horizontal camera framing | `Camera3D.KEEP_WIDTH` |
| Cursor-projected IME candidate position | `_update_ime_anchor()` |
| PTY resize after a window change | `_on_window_size_changed()` |

Use screen-space background rendering from `world_background.gdshaderinc`.
Keep terminal image geometry aligned with the grid; enable image storage and
register a PNG decoder when replacing the native terminal setup.

## Terminal API

### Signals

| Signal | Event |
| --- | --- |
| `keystroke(cell, unicode)` | Key delivered to the terminal |
| `cursor_moved(cell)` | Cursor position changed |
| `output(bytes)`, `grid_resized(cols, rows)` | Output or grid change |
| `bell()`, `exited(code)`, `title_changed(title)` | Bell, shell exit, or title |
| `ui_state_changed()`, `frame_changed()` | Semantic state / rendered pixels changed |

### Commands

| Call | Use |
| --- | --- |
| `respawn()` | Restart the shell in place |
| `send_text(text)` | Write raw terminal input |
| `paste_text(text)` | Paste with control stripping and bracketed-paste handling |

Each tab has its own terminal, viewport, shell, and scrollback. For transitions,
capture the outgoing terminal before switching and the incoming terminal after.
A newly opened tab may not have drawn its first output yet.

## Trust and recovery

### Plugin execution

Godot world plugins run as unrestricted code in the app process. Only install
plugins you trust. The kit provides reusable behavior, not a sandbox.

### Loading and failure

The host owns shell-exit policy and plugin loading. `--no-plugin` starts Flat;
failed initial loads fall back to Flat. A running plugin has no watchdog or
emergency unload shortcut.

The plugin manifest uses `api: 1`; unsupported versions are rejected. Package a
world as a PCK plus its manifest. GDScript needs no separate compiler; native
extensions need platform-specific binaries and signing.

See [Publishing a world](publishing-a-world.md) and
[terminal preferences](../internals/terminal-config-design.md).
