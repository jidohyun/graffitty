# World settings reference

Edit `client.toml` and restart the client to apply world settings.

## World settings

Choose the table for your world:

| World | Settings table |
| --- | --- |
| Flat 3D | `[worlds.flat-3d]` |
| Flat 2D | `[worlds.flat-2d]` |
| Bistro (separate download) | `[worlds.bistro]` |

- A world's `terminal` subtable overrides global `[terminal]` appearance.
- Worlds validate their own settings; `--check-config` does not check these tables.
- Plugin authors: see [world-owned settings](../developers/worlds-and-plugins/authoring-a-world.md#world-owned-settings).

### Pane padding and rounded corners

```toml
[worlds.flat-3d.terminal_window]
padding = [8, 8, 8, 8] # Left, top, right, bottom.
corner_radius = 12    # 0–64; 0 for square corners.
```

Use `worlds.flat-2d` for Flat 2D.

## Change a world setting from the menu

A `SetWorldSetting` menu entry sets one key of a world's `[worlds.<id>]` table.
For example, for a world whose settings include `weather.kind`:

```toml
[[menu.items]]
label = "View::Weather::Snow"
action = "SetWorldSetting"
world = "my-world"
setting = "weather.kind"
value = "snow"

[[menu.items]]
label = "View::Weather::Off"
action = "SetWorldSetting"
world = "my-world"
setting = "weather.kind"
value = "none"
```

- The entry shows only while `world` is the active world.
- The entry is checked while the setting has that value, so entries for one setting act as a choice.
- The world checks the value. An unknown setting or invalid value is not applied and logs a warning.
- The choice is remembered for the next launch. Your own `[worlds.<id>]` keys in `client.toml` still win.
- Worlds apply some settings at once; others take effect the next time the world loads.
- `setting` names a world setting, not one under `terminal`.

Each world's documentation lists its settings.

## Terminal backdrop blur per world

Blur scenery behind translucent panes while keeping text sharp. This does not blur the desktop behind the app.

```toml
[worlds.flat-3d.terminal_window]
blur_radius = 8 # 0–32; default 0.

[worlds.bistro.terminal_window]
blur_radius = 8
```

Blur needs visible scenery: opaque panes and solid backgrounds hide the effect.

In a 3D world, camera depth of field also blurs scenery on Forward+ and Mobile.
OpenGL Compatibility keeps the terminal's shader blur and the per-world backdrop
blur. Scenery stays in focus outside the blurred pane.

## Tab and session transitions

Use **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Tab Transition / Session Transition**.

| Transition | Choices | Default |
| --- | --- | --- |
| Tab | None, Push/Pull | Push/Pull |
| Session | None, Fly away, Fly away and in | Fly away in Flat worlds; Fly away and in for scenery worlds |

```toml
[worlds.flat-3d.tab_switch]
effect = "push_pull" # Or "none".

[worlds.flat-3d.session_switch]
effect = "fly_away" # Or "none", "fly_away_and_in".
```

**Fly away** reveals the destination while the old view disperses. **Fly away and in** also animates the arriving letters.

See [letter and dust settings](session-flight-settings.md).
