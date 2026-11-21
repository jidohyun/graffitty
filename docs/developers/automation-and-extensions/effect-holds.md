# Pause effects from a program

Use a hold to turn off selected effects while a pane is focused.
Switching away removes its influence; switching back restores it.

## From a shell or script

```sh
gft effects hold demo --off all --on cursor_trail --until pane
gft effects release demo
gft effects list
```

This keeps effects off, except the cursor trail, until released or the pane closes.
Reusing a hold ID replaces that hold.

| Option | Use |
| --- | --- |
| `--off sparks,camera` | Disable named effects or groups |
| `--on cursor_trail` | Keep an effect on despite other holds in this pane |
| `--target %12` | Manage another pane in the workspace |
| `--osc` | Print a terminal sequence; useful over SSH |
| `gft effects release` | Release every hold in the pane |

`--on` cannot override context rules or the Off effect profile.

## Scopes

| `--until` | Hold ends when… |
| --- | --- |
| `process` (default) | Foreground process group changes, such as an editor exiting |
| `pane` | Pane closes or terminal resets |
| `clear` | Explicitly released |

Every scope can be released manually. A short shell command usually needs
`--until pane` to keep its hold after the command exits.

## Effect names

| Selector | Effects |
| --- | --- |
| `all` | Everything |
| `camera` | Zoom, tilt, drift, shake, depth of field |
| `sheet` | Curvature, ripple, splash, gloss, shadow |
| `typing` | Camera, curvature, ripple, splash, lighting, pane zoom |
| Individual names | `sparks`, `cursor_trail`, `pane_zoom`, `lighting`, `tab_switch`, `session_switch` |

Use dotted names such as `camera.tilt` or `sheet.ripple` for one effect.
These match [context-rule selectors](../../customize/effect-rules.md#context-rules-and-actions).

## Editor and keyboard integration

`graffitty.nvim` exposes `require("graffitty.effects")` with `hold`, `release`,
`watch`, and `setup`. Use editor callbacks for mode- or filetype-specific holds.

Bind `ReleaseEffectHolds` to clear all holds in the focused pane.
**Prefix, R** settles motion once; it does not release holds.

The filetree can place its own hold while open;
see [Filetree](../../everyday-use/filetree.md#holding-effects-while-a-filetree-is-open).

## Terminal protocol

Skip this section when invoking `gft` or the editor integration.

For integrations that cannot invoke the CLI:

```text
ESC ] 4723 ; effects ; hold=<id> ; off=<names> [; on=<names>] [; until=<scope>] BEL
ESC ] 4723 ; effects ; release=<id> BEL
ESC ] 4723 ; effects ; release BEL
```

Inside tmux, wrap the sequence in DCS passthrough.
`gft effects hold ... --osc` wraps it automatically; see [pane claims](pane-claim.md).
Unknown effect names or malformed sequences are ignored.

The server shares holds with connected clients. Holds do not rewrite world
settings or profiles. For implementation checks, use
`tests/godot/test_session_effects.py --case adaptive`.
