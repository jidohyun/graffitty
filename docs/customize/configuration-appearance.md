# Terminal appearance

Choose **View → Effects Profile → Off** for a still workspace, or **Mild** for subtle motion.
Menu choices are remembered between launches.

## Change colors

Add this to `client.toml`:

```toml
[terminal]
foreground = "#abb2bf"

[terminal.background]
color = "#282c34"
alpha = 0.85
```

When the renderer reports that desktop transparency is unavailable, Graffitty uses
an opaque window and turns off desktop blur. Translucent panes can still show the
world behind them.

## Change text size

Use **Edit → Fonts** for the current run. For saved fonts, use
[shell and font settings](server-configuration.md#fonts).
Camera zoom changes framing; font size changes the terminal grid.

## Add motion

| Change | Menu |
| --- | --- |
| Choose a complete look | **View → Effects Profile** |
| Change the cursor trail | **View → Cursor Trail** |
| Tune individual effects | **View → Effects…** |

Start with **Mild** and change one effect at a time.
The [effects gallery](effects.md) has previews and copyable settings.

## Keep related panes in view

In **Effects…**, choose adaptive zoom and the groups to include.
Manual pan or zoom pauses adaptive movement; fresh typing resumes it.
See [typing effects settings](typing-effects.md#framing-related-panes-together)
for configuration examples.

## Save your choices

Menu choices persist between launches. Explicit values in `client.toml` take
precedence at startup. Tab and session transitions are remembered per world.

## More settings

- [Cursor, selection, clipboard, and scrolling](terminal-settings.md).
- [Trail styles, particles, pane zoom, and profiles](typing-effects.md).
- [Settle or disable effects for an application](effect-rules.md).
