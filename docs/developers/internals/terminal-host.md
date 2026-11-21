# Terminal host and worlds

The host keeps sessions alive while worlds control presentation.
For app controls, see [Tabs and panes](../../everyday-use/workspaces.md).

## Run from source

```sh
mise run dev
mise run dev -- --bg='#101822' --opacity=0.75
mise run dev -- --plugin=bistro
```

| Option | Use |
| --- | --- |
| `--no-plugin` | Start Flat |
| `--plugin=WORLD` | Load an installed world by id, or a `.pck` by path |
| `--config=PATH` | Select client configuration |
| `--bg`, `--opacity` | Override backdrop color and opacity |
| `--motion-render-scale=1` | Keep full scenery resolution during motion |

## Host contracts

### World lifetime

World switches preserve terminal nodes, PTYs, browsers, and scrollback.
Configure `SwitchWorld` menu entries explicitly in `client.toml`.

Failed runtime switches leave the current world active. Failed initial loads
fall back to Flat. Plugins run unrestricted Godot code.

| Component | Responsibility |
| --- | --- |
| `TerminalHost.gd` | Validate manifests, mount packs, create worlds |
| `TerminalWorld.gd` | Terminal presentation, framing, IME, effects |
| `TerminalSurface3D.gd` | Placeable screen and viewpoint |
| `WorldSettings.gd` | World settings and effects |
| `TerminalWorldProbes.gd` | Optional diagnostics |

See [plugin design](../worlds-and-plugins/design-plugins.md) and [world authoring](../worlds-and-plugins/authoring-a-world.md).

## Pack and load a world

Follow [Publishing a world](../worlds-and-plugins/publishing-a-world.md).
Source launches load the same installed packs as the packaged app; they never
load world files from the checkout.

Manifests use `api: 1` and an entry under `res://worlds/`. Prefer a
`PackedScene` whose root exposes `host`. Packs mount without replacing resources.
World changes need no native compilation.

### Tab lifecycle

Tabs have independent terminal state. Moving tabs between windows in the same app
preserves their shells.

Closing checks for running jobs on macOS/Linux. Running, stopped, or unknown
process state requires confirmation; cancelling leaves the PTY alive.
See [Sessions](../../everyday-use/sessions.md) and [multiple windows](../../everyday-use/multi-window.md).

### Background rendering and focus

Static workspaces stop drawing. Output, input, cursor blinking, browser frames,
and animation wake the compositor.

| State | Rendering |
| --- | --- |
| Rest | Native-resolution terminal overlay |
| Camera flight | Combined depth-tested terminal/scenery pass |
| Sustained motion | Scenery uses `motion_render_scale` |
| Camera still | Restore `render_scale`, draw once, sleep |
| Focus lost | Finish active flight; pause scenery and camera effects |

Terminal output and UI continue under the background frame cap.
Unfocused resizes refresh scenery once. `--no-focus-skip` bypasses its focus pause.

Avoid writing unchanged camera or shader values every tick; those writes can
wake Godot rendering. See [render costs](render-cost.md) and
[idle rendering](idle-rendering.md).

### Terminal backdrop and effects

Flat uses a full-window backdrop; authored worlds may use bounded sheets.
Cell backgrounds, selections, images, and glyphs keep their own coverage.

The [effects component](../worlds-and-plugins/terminal-effects-api.md) handles particles, trails,
ripple, and splash. User settings live under [appearance](../../customize/configuration-appearance.md).

## Verification

```sh
godot --headless --path frontends/godot/project --script tests/run.gd
```

Interaction scenarios and evidence requirements live in `tests/llm-e2e/README.md`.
