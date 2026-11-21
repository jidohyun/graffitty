# Session model API

Read host-owned models; worlds never parse terminal output. Models and PTYs
survive world changes. Free only the world's presentation nodes.

## Persistent session nodes

| Lookup | Result |
| --- | --- |
| `host.session_model(id)` | Model, or null for an unopened session |
| `host.active_session()` | Active model |

| Property | Meaning |
| --- | --- |
| `id`, `title`, `cwd` | Stable integer session ID, terminal title, OSC working-directory URI |
| `progress_state`, `progress_value` | State below; percentage 0–100 or -1 for unspecified |
| `scroll_total`, `scroll_offset`, `scroll_page` | Total rows, fractional top visible row (zero-based), visible row count |
| `alternate_screen` | Full-screen alternate buffer; scrollback commands are ignored here |
| `has_exited`, `exit_code` | Shell termination; code is null until the exit event |
| `terminal` | Underlying native Terminal node for lower-level input/rendering APIs |

## Snapshots and signals

| API | Result |
| --- | --- |
| `snapshot()` | Detached terminal values, including columns/rows |
| `scroll_snapshot()` | total, offset, page, alternate_screen, at_bottom |
| `capabilities()` | Available title/progress/scroll/cwd data |

Connect once, then read the snapshot; signals do not replay old state.
Signals are `changed()`, `title_changed(title)`, `progress_changed(state,value)`,
`scroll_changed(dictionary)`, `bell()`, and `exited(code)`.

Notifications coalesce state changes rather than preserving every OSC event.
Rendered-frame updates and a 10 Hz metadata/inactive-session fallback refresh
snapshots. Title, bell, and exit also use native events; no texture readback is needed.

## Scroll commands

`scroll_to(row)`, `scroll_by(rows)`, and `scroll_to_bottom()` control the viewport,
not synthetic wheel events. Fractional rows are accepted and clamped.
`snapshot()` separates integer offset and fraction; `scroll_snapshot().offset`
and `scroll_offset` combine them. Alternate-screen scrollback commands are ignored.

## Protocol boundary

Native parsing owns OSC 0/2 titles, OSC 7 cwd, scrollback, and alternate-screen state.
The passive progress observer reads `9;4;state[;value]` without withholding VT bytes.

| Progress state | Value |
| --- | --- |
| 0 / NONE | Clear, -1 |
| 1 / NORMAL | Percentage; omitted percentage starts at 0 |
| 2 / ERROR | Percentage or -1 |
| 3 / INDETERMINATE | -1 |
| 4 / PAUSED | Percentage or -1 |

Progress remains until changed, cleared, or respawned. It is explicit metadata,
not inferred output. The observer accepts split ESC-prefixed sequences ending
in BEL or ESC-backslash; it clamps percentages to 100.
Invalid/overlong fields and nested DCS/APC/PM/SOS content are ignored.
Raw 8-bit C1 introducers are unsupported.

```sh
printf '\033]2;Building Bistro\007'
printf '\033]9;4;1;42\007' # normal, 42 percent
printf '\033]9;4;3\007'   # indeterminate
printf '\033]9;4;0\007'   # clear
```

## Power events

Check `host.power.available` before reading `on_battery`.
`source_changed(on_battery: bool)` runs on Godot's main thread; all windows share
the monitor. Prefer `[power]` settings for automatic world switching.

Native event sources are IOKit on macOS, UPower/D-Bus on Linux (UPower required),
and power-setting notifications on Windows.
