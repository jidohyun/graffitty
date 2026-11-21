# Terminal configuration ownership

The host owns user preferences. Each world resolves its terminal presentation
without restarting existing PTYs or deleting history.

## Implemented scope

| Owner | Settings |
| --- | --- |
| TerminalConfig | Fonts, colors, cursor, background, overlays, history, process setup, clipboard, links, image budgets, terminal keys |
| World | Geometry, padding/corners/feathering, camera, lighting, scene animation |
| Host UI | Tabs, windows, browser shortcuts, menu callbacks |

Use the [current user reference](../../customize/terminal-settings.md) for options;
[research sources](terminal-config-research.md) explain the design background.

## World contract

The kit calls `configure_terminal(user_copy)` once per new world, validates the
result, and stores `world.terminal_config`. The world may return a changed copy
or a fresh object. No later global overlay overrides its decision.

```gdscript
func configure_terminal(user: TerminalConfig) -> TerminalConfig:
    var chosen: TerminalConfig = user.copy()
    chosen.background.alpha = 0.3
    return chosen
```

Custom worlds may read `host.terminal_config`, copy per surface, and call
`apply_to(terminal)` **before tree entry** to include spawn settings.
`apply_live()` applies behavior while a custom renderer owns presentation.
The kit handles texture/font scaling and native font actions.

Font sizes are reference-layout pixels. Kit padding is world-owned and capped
at 20% of the smaller terminal dimension. Flat uses a full-window backdrop;
Bistro uses bounded translucent sheets. Effect presets load independently.

## Lifecycle and input

| When | Applied settings |
| --- | --- |
| Session spawn | Shell, login, cwd, environment, integration, history, image budgets |
| Present existing session | Live appearance and bindings; no process restart |
| Focused GUI input | Native terminal shortcuts |
| Search/selection active | Their modal input rules |

Consumed key press/repeat/release sequences never reach the PTY, including Kitty
releases. Unbound activation chords pass through. Scrollback actions fall through
on alternate screen. Host/window actions remain separate.

`key_bindings = []` removes activation bindings; `ignore` swallows a chord.
Native InputEventKey matching is exact, so Ctrl+F differs from Ctrl+Shift+F.

## Validation

Typed fields and `validate()` catch range, enum, and duplicate-key errors.
Copies isolate nested appearance, arrays, environments, and key resources.
An invalid user layer leaves the previous valid configuration. An invalid world
result falls back to a fresh TerminalConfig.
