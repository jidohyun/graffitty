# Mod API reference

Start with [JavaScript mods](mods.md) to create a working panel.

## Replace a built-in

Use its existing ID to inherit its host and defaults:

```toml
[mods.agents]
entry = "./mods/my-agents/main.js"
title = "My Agents"
```

Bundled IDs include `sessions`, `agents`, `pane-status`, `resource-monitor`,
`status-line`, `pane-strip`, `tab-menu`, `command-line`, `pane-header`, and
`touch-controls`. See `crates/client-config/defaults/mods.toml` for defaults.
A built-in override must preserve its host contract.

## Choose a host

| `host` | Presentation | Notes |
| --- | --- | --- |
| `panel` | Dockable or floating window | `place`, `sides`, `size`, `title` |
| `bar` | Titleless top/bottom strip | Cannot float or fold |
| `pane` | One strip per pane | Receives `{window, pane}`; presses pass through |
| `embedded` | Existing native presenter's content | Preserve its props and hit IDs; arbitrary new mounting points are unsupported |

New IDs need both `entry` and `host`. IDs use letters, digits, `_`, and `-`.

| Setting | Effect |
| --- | --- |
| `enabled = false` | Disable the mod |
| `open` | Initial visibility; saved state wins |
| `place`, `sides` | Initial and allowed dock sides; `none` floats |
| `after` | Order after another mod on the same side |
| `props` | Script options; host context overrides conflicting keys |

Panels save their placement and folded state. Click the title to fold or unfold;
drag it to move or dock. Desktop floating panels use native windows; Android embeds them.

## Elements and interaction

| Need | API |
| --- | --- |
| Layout and content | `div`, `h_flex`, `v_flex`, `svg`, `image` |
| Styling | `gap`, `px`, `h`, `rounded`, `bg`, `text_color`, `hover` |
| Interaction | `id`, `tooltip`, `tooltip_on_truncate` (show the full text when `truncate` adds an ellipsis), `on_click`, `on_mouse_down`, `on_mouse_move` |
| Scrolling | `overflow_x_scroll()` or `overflow_x_scrollbar()` for horizontal scrolling, `overflow_y_scroll()` or `overflow_y_scrollbar()` for vertical scrolling. Chain both axes when needed. |
| Animation | `.spin(900)`, `.frames(["⠋", "⠙"], 90)` |

Give the container a bounded size and its scrolling children a width or height
they keep, for example with `.flex_none()`. The dominant axis of a swipe selects
the scroller. Trackpad and touch gestures stretch past either end and spring
back on release. Wheel steps and scrollbar drags stop at the bounds. The
default bars fade after scrolling or pointer activity. Use `.mode("always")`
to keep them visible, `.mode("hover")` for pointer hover, or `.mode("scrolling")`
to show them while dragging a thumb.

Import `scrollOffset` and `scrollTo` from `graffitty`. After layout,
`scrollOffset("table")` returns `{ x, y }` in logical pixels for the element
with `.id("table")`. For example, `scrollTo("table", { x: 120 })` sets the
horizontal offset and preserves the vertical one. Both functions return the
current offsets, clamped to the last layout. Missing axes or IDs return zero
for the corresponding offsets.

SVG icons inherit text color; use `image(path)` for original-color artwork.
Text input, keyboard focus, popovers, retained child views, and text selection
are not available.

## Runtime state

Never retain `cx` across callbacks. Use `cx.timer.every(ms, callback)` and
`cx.timer.cancel(id)` for timers. `localStorage` persists per mod copy;
`shared` and `setShared` exchange state between mods.

## App data and actions

Read `sessions()`, `agents()`, `panes()`, `focused()`, `resources()`, `session()`,
`effects()`, `window()`, or `live(key)` from `graffitty`. `pane()` is available
only in a pane host. Data belongs to the hosting window.

Call `run(action, args)` with the same PascalCase actions used by menus and bindings:

```js
run("OpenPanel", { name: "builds" });
run("ToggleEffect", { effect: "camera.tilt" });
```

The generated declarations list data types and supported actions. They are written
on startup to `~/.local/share/graffitty/mods/graffitty.d.ts`, or the platform equivalent.
Point your editor's `jsconfig.json` at that file.

## Unavailable APIs

`exec`, `hc`, file access, and `watchFolder` reject calls. Overlay and notification
helpers are not routed yet.

## Backgrounds

```toml
[mods.agents]
background_opacity = 0.8
background_blur = true
background_blur_radius = 12
```

Leave the root background unpainted to show the panel surface. Opacity is 0–1;
blur radius is 0–64 logical pixels. Embedded panels cannot blur other embedded windows.
Native floating blur also depends on the user's window settings and compositor support.

The UI model uses Apache-2.0 work from herdr-app and gpui-kit;
see their notices under `licenses/`.
