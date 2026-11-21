# Workspace appearance

Choose a world and adjust spacing or motion. Saved settings go in `client.toml`;
see [Configuration](configuration.md) for its location.

## Choose a world

Pick a world under **View → World**. Flat 2D and Flat 3D come with the app.
On desktop, the menu also lists installed worlds, including
[Bistro](#install-the-bistro-world) and [other downloaded worlds](#add-a-downloaded-world). To open
one every time, [set the default world](#set-the-default-world).

## Install the Bistro world

[Bistro](https://github.com/graffitty/bistro-world) is an official world made
by the Graffitty project: a night-time Paris street and café with your panes
placed through the scene (about 400 MB).

```sh
gft world install bistro
```

This downloads the latest release into the `worlds` folder (see
[Add a downloaded world](#add-a-downloaded-world)) after checking it against
the release's `SHA256SUMS`. Add `--version <tag>` for a specific release.
Restart Graffitty and choose **View → World → Bistro**.

App updates don't update Bistro. To update it, run the same command again and
restart; it replaces the whole `bistro` folder.

## Add a downloaded world

A downloaded world is a folder named after the world's id, holding
`<id>.pck` and `<id>.json` side by side. Graffitty lists every world it finds
in the `worlds` folder of its data directory:

```text
~/.local/share/graffitty/worlds/
└── <id>/
    ├── <id>.pck
    └── <id>.json
```

If `XDG_DATA_HOME` is set, use `$XDG_DATA_HOME/graffitty/worlds` instead
(see [Desktop file locations](configuration.md#desktop-file-locations)).

1. Download the world's zip. Pick the release made for your Graffitty version.
2. Extract it into the `worlds` folder.
3. Restart Graffitty and choose the world under **View → World**.

Only install worlds from sources you trust: a world runs scripts inside
Graffitty.

App updates don't update downloaded worlds. To update one, delete its folder,
extract the new zip, and restart. Always replace the `.pck` and `.json`
together.

To remove a world, delete its folder and any `path` line naming it (see
[Set the default world](#set-the-default-world)). If a world fails to load,
Graffitty falls back to its built-in world.

## Set the default world

Set `path` in `client.toml` to the world Graffitty opens with, then restart:

```toml
[world]
path = "flat-2d"
```

Hardware-rendered desktops default to `flat-3d`, which adds depth effects;
Android, iOS, and software rendering default to `flat-2d`.

For an installed world, use its id. For example, to start in Bistro:

```toml
[world]
path = "bistro"
```

A value without `/` or a `.pck` suffix names an installed world by id. To load
a pack from somewhere else, give its path instead, for example
`"%(data)/worlds/bistro/bistro.pck"` (see
[Paths in client.toml](configuration.md#paths-in-clienttoml)). Tune a world's
panes under `[worlds.<id>]` in [World settings](world-settings.md).

## Adjust pane spacing

```toml
[tiling]
gap = 8

[worlds.flat-2d.terminal_window]
padding = [8, 8, 8, 8]
corner_radius = 12
```

Padding runs left, top, right, bottom. Use `worlds.flat-3d` for Flat 3D.
Set gap or corner radius to `0` for no gap or square corners.

## Zoom and pan

- Pinch, or **Cmd+scroll** on macOS / **Ctrl+scroll** elsewhere, to zoom.
- Right-button drag to pan.
- Choose **View → Main Area** to reset framing.

Each tab remembers its view. Rename panes and tabs with `gft pane rename`
and `gft tab rename`; omit the name to resume automatic titles.

## Desktop UI scale

Graffitty follows the display scale by default. Tabs, menus, dialogs and
terminal cells grow together. Moving a native window to another monitor
updates its scale on Windows and Wayland. On macOS, automatic scaling uses
the display's Retina backing scale.

To use a fixed scale on every desktop monitor, set `ui_scale` in
`client.toml` and reopen the frontend.

```toml
[window]
ui_scale = 1.5
```

Use `1.5` for 150%, another positive number for a different scale, or
`"auto"` to follow the desktop again.

On X11, Graffitty reads desktop-wide `Xft/DPI` from XSettings, then the
XSettings window scale, then the `Xft.dpi` X resource. For example, 192 DPI gives
200% with the default text size. The fallback is GNOME's window scale or
100%. `QT_SCALE_FACTOR` multiplies this result. Setting either `GDK_SCALE`
or `GDK_DPI_SCALE` overrides it with their product (each defaults to 1).

GNOME's text scaling preference applies separately to interface fonts on
X11 and Wayland, including with a fixed window scale. Shared terminals use
the session's font size and cell metrics.

## Reduce motion or frame rate

Choose **View → Tab Transition / Session Transition → None** to stop transition motion.
See the [effects gallery](effects.md) for other choices.

```toml
[window]
max_fps = 60
inactive_max_fps = 30
```

The defaults are 120 FPS while active and 30 FPS while inactive.
Both caps accept 1–240; the inactive cap cannot exceed the active cap.
Display refresh and VSync can limit the actual rate.

See [World settings](world-settings.md) for per-world overrides, backdrop blur,
and transition configuration. Use [letter and dust settings](session-flight-settings.md)
for session-flight tuning.
