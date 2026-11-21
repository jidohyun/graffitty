# Typing effects settings

Edit `client.toml` to tune effects. Start with [Terminal appearance](configuration-appearance.md) or the [effects gallery](effects.md) to choose a look.

## Add typing effects

### Cursor trails

Choose **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Cursor Trail**, or configure:

```toml
[terminal.effects.cursor_trail]
delay_ms = 1 # 0 disables trails.
style = "lightning" # smear, blaze, lightning
```

#### Tune individual styles

```toml
[terminal.effects.cursor_trail]
delay_ms = 1 # 0 disables trails.
style = "lightning" # smear, blaze, lightning
start_threshold = [2, 2] # Cells.
decay = [0.1, 0.4] # Smear corner decay, in seconds.

[terminal.effects.cursor_trail.smear]
color = "none" # Follow the cursor color.

[terminal.effects.cursor_trail.blaze]
duration = 0.5
color = "#ffb929"
accent_color = "#ff0000"

[terminal.effects.cursor_trail.lightning]
duration = 0.14
color = "#ffb929"
glow_color = "#bd0000"
jaggedness = 0.085
core_width = 1.15
glow_width = 5.5
```

Each style keeps its own settings when you switch styles.

### Typing particles and pane zoom

```toml
[terminal.effects.typing_particles]
preset = "sparks" # none, sparks, dots, fireworks, flames, glitter
amount = 6 # Particles per keystroke.

[terminal.effects.typing_pane_zoom]
scale = 1.1 # 10% larger while typing; 1.0 disables.
```

Pane zoom enlarges the typing pane without resizing the terminal grid.

### Framing related panes together

Adaptive zoom can keep a pane and its related tools in view.

In `client.toml`:

```toml
[effects.camera]
zoom_mode = "adaptive"
adaptive_group = { main_view = true, filetree = 0.25, chromium = false, spawned = false, graph = false }
```

| Value | Behavior |
| --- | --- |
| `false` | Do not include that group |
| `true` | Include it whenever it fits |
| 0–1 | Limit how much of the frame may be empty gap |

- Groups include the main area, filetree, browser, panes launched with `gft pane run`, and graph neighbors.
- Manual pan or zoom pauses adaptive movement; fresh typing resumes it.
- The **Effects…** dialog also has group controls.

## Effects profiles

Choose **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Effects Profile**.

Software rendering defaults to **Off**. Choose **World Default** or **Mild**
to enable motion, including on a remote desktop that draws with the CPU.

| Profile | Result |
| --- | --- |
| World Default | Use the world's effects |
| Off | Disable decorative effects |
| Mild | Subtle typing motion and surface effects |
| Exaggerated | Stronger motion and surface effects |

```toml
[effects]
profile = "mild"
disabled = ["camera.tilt"]

[effects.profiles.calm.camera]
zoom = 1.15
tilt_limit_deg = 3

[effects.profiles.calm.sheet]
ripple = 0.2
```

- Custom profiles use the same settings as `[effects]`, under `[effects.profiles.NAME]`.
- Names use lowercase letters, digits, `-` and `_`; built-in names are reserved.
- Profile camera zoom applies in **Typing zoom** mode. Adaptive zoom keeps its own fit.

### Remembered choices

- Menu changes to profiles, effects, trails, particles, pane zoom and transitions persist between launches.
- Values explicitly set in `client.toml` take precedence at startup.
- Transitions are remembered per world.
- To reset remembered choices, delete `~/.local/state/graffitty/remembered.toml` (or the equivalent under `XDG_STATE_HOME`).
- `--no-config` skips remembered choices.

See [cursor, selection, clipboard, scrolling, and copy-mode settings](terminal-settings.md).

See [application rules](effect-rules.md).
