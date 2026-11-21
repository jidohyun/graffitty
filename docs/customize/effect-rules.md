# Change effects for an application

Use a rule when effects should settle or stay off in a particular program. Edit `client.toml`.

## Context rules and actions

Use rules to change effects for a focused application. No app-specific rules are enabled by default.

```toml
[[rules]]
event = "app_changed"
app = "vim"
action = "SettleEffects"
include = ["typing"]
```

When the focused application changes to Vim, typing effects return to rest.
Fresh typing starts them again.

To keep effects off while Neovim is focused instead:

```toml
[[rules]]
event = "active"
app = "nvim"
action = "DisableEffects"
exclude = ["sparks"]
```

This leaves particles enabled. No application rules are active by default.

### Events and conditions

| Event | Action | When |
| --- | --- | --- |
| `app_changed` | `SettleEffects` | The foreground application changes |
| `focus_changed` | `SettleEffects` | Pane focus changes |
| `active` | `DisableEffects` | While the focused pane matches |

- Conditions `app` and `pane` accept a name or list of alternatives; both must match when supplied.
- Without conditions, the rule applies to every occurrence of its event.
- `include` defaults to `["all"]`; `exclude` defaults to `[]` and takes precedence.
- `SettleEffects` returns effects to rest until fresh typing.
- `DisableEffects` holds effects off while the condition matches. Overlapping rules combine.

### Effect names

| Name | Controls |
| --- | --- |
| `all` | All effects |
| `camera` | All `camera.*` effects |
| `camera.zoom`, `camera.tilt`, `camera.drift`, `camera.shake`, `camera.dof` | Zoom, tilt, drift, shake, depth of field |
| `sheet` | All `sheet.*` effects |
| `sheet.curvature`, `sheet.ripple`, `sheet.splash`, `sheet.gloss`, `sheet.shadow` | Bend, waves, splashes, gloss, edge shadow |
| `lighting` | Terminal lighting |
| `sparks` | Typing particles |
| `cursor_trail` | Cursor trails |
| `pane_zoom` | Typing pane zoom |
| `tab_switch`, `session_switch` | Tab and session transitions |
| `typing` | Camera, curvature, ripple, splash, lighting and pane zoom |

- **Prefix, R** settles the `typing` group.
- Existing particles and transitions finish their animations.
- Effects do not change terminal colors, layout or manual navigation.
- Ordinary SSH and tmux expose the outer process; rules cannot infer the app running inside them.
- Programs needing finer control can use [effect holds](../developers/automation-and-extensions/effect-holds.md).
