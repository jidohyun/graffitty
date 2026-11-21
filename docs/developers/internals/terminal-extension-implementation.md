# Native extension implementation

The extension adapts shared Rust state to Godot. Build it with the
[extension guide](../build-and-run/terminal-extension.md).

## What we changed

### Status strip geometry

`workspace-core::status_strip` owns placement/history and outside-edge paths.
Strip/place/carry/reanchor/Motion are engine-independent. WorkspaceLayoutCore
converts Godot rectangles; StatusStripPath samples the result.
Plan once before camera motion, animate geometry/opacity together, commit only
on completion, and reverse from the displayed frame. Paths avoid their own pane
but may cross neighbors. Shared `status-strip-navigation` tests cover Flat/Flat 2D.

### Terminal API

| Call | Result |
| --- | --- |
| `get_cursor_cell()` | Viewport column/row; (-1,-1) when hidden |
| `get_grid_size()` | Columns/rows |
| `get_cell_size()` | Pixel cell box |
| `get_cursor_render_info()` | Last painted rectangle in cells and resolved shape/color |

### IME

Native code activates composition on focus, projects candidate position, paints
preedit with terminal fonts/metrics, and suppresses physical keys consumed by IME.
Only the composing range is underlined; committed Unicode still passes through.

The macOS shim observes AppKit commands to replay unconsumed composition-ending
keys. Terminal Option keys become Alt without symbols/dead keys while preserving
Shift/layout. Other text controls keep native handling.
See [input contract](korean-input.md) and `tests/platform/macos/test_macos_terminal_alt.py`.
The reference engine patch is `patches/godot-ime-key-replay.patch`.

### Inline images

`terminal-core::image_render` resolves Kitty placements and Unicode placeholders
without painting placeholder glyphs. Erase/scroll/screen changes hide affected
regions. Tagged Sixel/iTerm previews follow erase without deleting ordinary Kitty images.

The owner interprets graphics and publishes placement metadata plus immutable,
content-addressed assets through the one terminal scene format.
Client-core assembles revisioned transactions off-thread; explicit commit atomically
replaces detached checkpoint state. Godot receives prepared objects directly.

Visible assets import verified local Metal storage or use portable PNG/raw RGBA
decoded off-thread. Unchanged textures survive placement changes; references and
cache budgets control lifetime.
Tests: `terminal_images_input_smoke.gd`, `terminal_scene_smoke.gd`,
`tests/server/test_terminal_scene.py`.

### Native windows

| Platform | Adapter and rule |
| --- | --- |
| macOS | Refresh native traffic-light hover state through runtime-checked selector; preserve native actions |
| Windows | Per-HWND subclass extends caption while retaining resize/system controls/Snap Layouts; scaled overlay paints glyphs |
| Linux | Client controls plus compositor-managed Godot drag/resize APIs |

Windows removes the subclass on destruction. Live window tests cover hit regions,
scaling, controls, fullscreen, detach, and close delivery. macOS tests check all
three buttons' hover/exit states and actions.

### Build plumbing

`build.rs` compiles the macOS shim and links AppKit/Foundation.
`unicode-width` handles preedit advance; `cc` builds native sources.
`tools/build_godot.py` installs and signs the library.

### Audio capture

Desktop/iOS capture uses a worker after `DictationAudio.start_capture()`.
Stop drains through release time; cancel/disposal closes without sending buffered
audio. Android retains its AAudio/Godot path. Server-only builds omit device capture.

## Known open items

Use `GRAFFITTY_KEY_TRACE=1` to inspect keycode, Unicode, press/release, and composition.
Candidate placement in textured worlds must use the projected cursor anchor;
see [current kit integration](korean-input-evidence.md#current-project-integration)
before treating the old global-position limitation as current.
