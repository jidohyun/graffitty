# Terminal settings reference

All settings below belong in `client.toml`. Start with [Terminal appearance](configuration-appearance.md) for common changes.

## Terminal config

Set these values under `[terminal]` unless an example names another table.

### Colors and selection

```toml
[terminal]
foreground = "#abb2bf"
selection_background = "#7f6699"
selection_foreground = "none"

[terminal.background]
color = "#282c34"
alpha = 0.85
```

- Colors accept hex RGB/RGBA; `"none"` means transparent.
- Set both selection colors to `"none"` for reverse-video selection.
- Worlds can override appearance. See [world settings](world-settings.md#world-settings).

| Setting | Controls |
| --- | --- |
| `palette` | Sixteen ANSI colors |
| `palette_overrides` | Individual color indices, e.g. `{ "17" = "#123456" }` |
| `text_outline`, `text_outline_width`, `text_outline_color` | Text outline; width 0–32 |

### Cursor

| Setting | Choices |
| --- | --- |
| `cursor_shape` | `auto`, `block`, `bar` / `beam`, `underline`, `hollow` |
| `cursor_color` | Hex color |
| `cursor_blink` | `auto`, `on`, `off` |
| `cursor_blink_interval_ms` | Blink interval |
| `cursor_beam_thickness` | Beam width |
| `cursor_underline_thickness` | Underline height |

### Fonts and zoom

- Configure [fonts on the server](server-configuration.md#fonts).
- **Edit (<img class="menu-icon" src="../images/menu/square-pen.svg" alt="" width="18" height="18">) → Fonts** changes them for the current run.
- Font-size shortcuts affect the focused pane; new panes inherit the last chosen size.
- Camera zoom changes the view without changing text size or the terminal grid.

For appearance overrides under `[terminal]`:

| Setting | Value |
| --- | --- |
| `font_family`, `font_fallbacks` | Family name; ordered fallback families |
| `font_regular_path`, `font_bold_path`, `font_italic_path`, `font_bold_italic_path` | Font files |
| `font_size` | 1–72 |
| `ligatures` | `true` / `false` |
| `line_height`, `column_width` | 0.5–3.0 |
| `font_features`, `font_variations` | Tables keyed by four-character OpenType tags |
| `symbol_maps` | Unicode ranges, e.g. `[{ first = 0xE000, last = 0xF8FF, family = "Symbols Nerd Font" }]` |

### Clipboard and links

These settings belong under `[terminal]`.

| Setting | Choices or purpose |
| --- | --- |
| `clipboard_read` | `deny`, `ask`, `allow` for program clipboard reads |
| `clipboard_write` | Allow programs to write to the clipboard |
| `open_hyperlinks` | Enable opening links |
| `hyperlink_patterns` | Extra link patterns as regular expressions |

### Scrolling and selection

| Setting | Choices or purpose |
| --- | --- |
| `scroll_multiplier` | Scroll speed, 0–100 |
| `selection_word_boundaries` | Characters that separate selected words |
| `copy_on_select` | `none`, `primary`, `clipboard`, `both` |
| `quick_select_patterns` | Extra [Quick Select](../everyday-use/quick-select.md) patterns |
| `quick_select_defaults` | Include built-in patterns |
| `quick_select_alphabet` | Unique lowercase letters for labels |

Scrolling with a precision touchpad, or with a finger on a touchscreen, can pull
the text a little past the first or last row. It springs back when you let go,
as a page does in a web browser. A mouse wheel stops at the ends, and so do
full-screen programs such as Vim.

### Bell

```toml
[terminal]
audible_bell = false
visual_bell_duration_ms = 150
visual_bell_color = "#7f6699"
```

Set `visual_bell_duration_ms = 0` to disable the flash; maximum 60000.

## Copy mode

Customize word navigation using Neovim-style `iskeyword` rules:

```toml
[terminal]
iskeyword = ["@", "48-57", "_", "192-255", "-"]
```

- This example adds hyphens to the default word characters.
- The list replaces the defaults; include the entries you want to keep.
- Later exclusions win: add `"^_"` to exclude underscores.
- Space-prefixed word navigation uses fixed rules.

See [copy-mode keys](../everyday-use/copy-mode.md) for navigation and selection.
