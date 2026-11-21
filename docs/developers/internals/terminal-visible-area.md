# Terminal visible-area tracking

Use the latest prepared terminal frame to fit content. Tracking alone does not
enable adaptive zoom and is not semantic input-box detection.

## Ownership

Rust `terminal-core::visible_area` computes cell bounds during the existing paint
iteration. Publish after frame preparation. Do not parse VT again or call a
second `RenderState::update`, which consumes dirty flags.

## Read the bounds

`Terminal.get_visible_area()` returns:

| Field | Meaning |
| --- | --- |
| `generation` | Changes with bounds/grid/cursor/graphics, not identical repaint |
| `grid` | Columns/rows of the prepared presentation |
| `text` | Non-whitespace glyphs and persistent decorations |
| `content` | Text plus nondefault backgrounds, including inverse blanks |
| `cursor` | Separate cell even when hardware cursor is hidden |
| `framing` | Content/cursor union; whole grid for graphics |
| `graphics_present` | Text bounds cannot claim complete graphic coverage |
| `scroll_fraction` | Fractional row translation |
| `cell_size`, `grid_origin` | Pixel conversion with padding/scroll translation |

Rectangles use viewport cells with exclusive right/bottom edges and clip to the grid.
Wide glyphs include both columns. Missing rectangles mean empty; `{}` means no prepared frame.

Spaces, concealed text, transient selection/search/hover, and blinking must not
change footprint. IME and temporary UI are excluded. Consumers handle clipped
fractional-scroll fringe rows separately.

## Timing and scope

Observe prepared frames, not incoming packets. Coalesced output yields one observation;
unpainted terminals keep the last value. Clear/scroll/alternate-screen/resize
rebuild from the viewport, preventing accumulating bounds.
Convert cells through metrics, padding, and existing projection. Graphics need
conservative framing; tracking changes no protocol schema.

## Adaptive zoom

Choose **Effects → Zoom mode → Adaptive zoom**, or configure:

```toml
[effects.camera]
zoom_mode = "adaptive"
adaptive_zoom_in_seconds = 10.0
adaptive_zoom_out_seconds = 1.5
```

| Policy | Contract |
| --- | --- |
| Mode | Adaptive is default; mutually exclusive with `typing` |
| Authored fixed zoom | Neutralized in adaptive mode, restored on return |
| Effect gate | Still `camera.zoom` |
| Timing | Zoom in/out settling times, 0.001–60 s; lower is faster |
| Target | Absolute magnification; automatic cap 3× terminal pixels |

Manual magnification above 3× is not undone. Saved navigation stays unchanged.
Times describe exponential settling (~99.9%), not delays. Direction follows the
current animated zoom; no threshold/debounce. Brief blank frames approach slowly;
full output can reverse quickly. Existing typing hold/rise/decay still applies.

Main-group typing frames Main plus selected companions and ignores output-only
changes. Main includes where typing pane zoom will draw its tiles, since a
full-width or full-height tile grows past Main's edges. For ungrouped/stashed/untiled panes, `adaptive_fit` adds two columns,
four rows, and 10% margin where possible. Padding alone cannot zoom below rest;
cursor containment may leave surrounding content outside view.

### Framing related panes together

```toml
[effects.camera]
adaptive_group = { main_view = true, filetree = 0.25, chromium = false, spawned = false, graph = false }
```

| Relation | Included peers |
| --- | --- |
| `main_view` | Main area for focused tiled panes; boolean |
| `filetree` | Open tree or its owner |
| `chromium` | Opened browser viewers, including filetree viewers |
| `spawned` | `gft pane run` children or parent |
| `graph` | Live, unmuted graph neighbors |

Relations add together. Missing entries keep defaults; Main/Filetree are enabled
by default. Other values accept false/true or a 0–1 maximum empty-gap share.
Measure gap on the separating axis against the current framed extent.
Touching/overlapping panes score 0. Add nearest companions first; each tests
against the accumulated frame. Main+Filetree measures the gap against Main.

### Contain projected geometry

The final safety fit samples a 9×9 curved-sheet grid. Rust `contain_projected`
tries authored tilt, then reduced tilt, then minimal frustum expansion/shift.
Near-plane intersections move the eye back. Flat 2D uses an orthographic adapter.
Already-fitting frames stay unchanged; the safety pass adds no padding.

Actual geometry overflow may override the no-zoom-out floor: curvature, pane
magnification, or manual scale can otherwise make containment impossible.
This does not rewrite navigation or effect settings.

### Animate one destination

Set the fitted target before consuming time; repeated projection/input queries
must not advance it again. Interpolate lens at sheet-focus depth so lens/dolly
cannot oppose each other. Input and rendering share the same displayed frame.
Both renderers use the same filter. Typing ends by easing to rest.

Coverage excludes particles/glow/shadows and exact shader extrema. Curvature is
sampled. Physical-device comfort and acceptance remain unverified.

## Verification

Animated projection correction regression checks:
- `cargo test -p graffitty-scene-core --lib`: 75 passed, including coupled dolly/lens scale monotonicity.
- Godot unit filters `adaptive_zoom`, `camera_follow`, `routed_camera`, and
  `navigation_tilt`: 35 passed, covering additive Main/Filetree grouping, stable
  focus changes within Main, displayed-frame convergence, and existing flight behavior.
- `tests/adaptive_projection_smoke.gd`: passed headless and graphically on macOS;
  the actual Flat 2D adapter settles without pan/zoom reversals through focus,
  filetree reveal and idle, with no first-frame cuts.
- `tests/flat_2d_foreground_clip_smoke.gd`: passed graphically on macOS.

Earlier visible-area tracker checks:
- `cargo test -p graffitty-terminal-core --lib`: 114 passed.
- `cargo check --manifest-path frontends/godot/extension/Cargo.toml`: passed.
- `godot --headless --path frontends/godot/project --script tests/visible_area_smoke.gd`:
  12 checks passed through real libghostty and the production Rust paint pass,
  covering sparse/wide text, blank/background/concealed/blinking cells, identical
  redraws, alternate-screen return and erase/resize.

Headless and rendered automated checks establish their assertions, not physical-device acceptance or a performance benchmark.
