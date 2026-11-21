# Flat 2D renderer and evidence

Implementation details and recorded comparisons for the bundled Flat 2D world. These results apply to the hardware and cases listed below.

## Built-in Flat 2D world

Launch with `--plugin=flat-2d`, set `[world] path = "flat-2d"` in the application
config, or add a **View (<img class="menu-icon" src="../../images/menu/eye.svg" alt=""
width="18" height="18">) → World → Flat 2D** `SwitchWorld` menu entry with `path =
"flat-2d"` in `client.toml`. World menu entries are explicitly configured; the built-in
world is not automatically added to an existing menu.

Flat remains available. This built-in world requires no additional DVC assets. Switching
preserves live terminals, panes, tabs, graph wires, and chromium sessions.

The renderer uses Camera2D, one workspace Sprite2D, a flat background, batched
MultiMeshInstance2D typing effects, and a Polygon2D cursor trail. Sparks share the 3D
renderer’s tapered streak, fork, glow and color shader. Tab transitions capture native
glyph layers separately from whole pane frames; they do not tile a screenshot.

The common TerminalSpace canvas supplies exactly the same pane chrome, terminal text,
images, graph links, and input controls. It retains the shared host/session helpers;
their inherited Node3D root is only an API container, with no 3D render camera,
surfaces, lights, or scenery passes. The world viewport disables 3D.

Camera2D's inverse transform maps pointer input and IME placement.

### Supported effects

Compatible effects remain: typing zoom, cursor following, pan, drift, shake,
ripple/splash, cursor trails and particle presets. Tab switching uses
batched 2D scatter and eased camera movement. These particle/scatter
variants are planar; depth travel, camera tilt, saddle curvature, lens depth of
field, depth tint, and lifted image planes are omitted. Zoom and workspace
navigation retain their existing configuration and gestures.

### Visual boundary

The resting view matches Flat's framing, including its small decal magnification,
and uses the same sheet shader calculations. On the Windows comparison below,
all pixels matched within 2/255 per color channel (mean absolute difference
0.302/255). The remaining difference is render-pipeline rounding, so this is
visually matching rather than byte-identical output.

## Recorded comparison — 2026-10-02

Godot 4.7.2, Direct3D 12 Forward+, GTX 1660 SUPER, i9-12900KS, 1600×1000 window. Same
process, live PowerShell sessions, pane layout and source texture resolution; uncapped,
VSync disabled. Each case runs in A/B/B/A order, with one second warmup and three
seconds sampling per run. Values average the two runs per renderer.

Extra effects are disabled in both; zoom/pan uses the same scripted camera path. These
measurements compare the renderer, not LLM throughput or all-effects cost.

| Panes / scenario | Flat FPS | Flat 2D FPS | Flat mean frame | Flat 2D mean frame | FPS gain |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 / resting | 589 | 836 | 1.699 ms | 1.197 ms | 42% |
| 1 / zoom + pan | 556 | 772 | 1.798 ms | 1.296 ms | 39% |
| 8 / resting | 275 | 320 | 3.634 ms | 3.125 ms | 16% |
| 8 / zoom + pan | 264 | 305 | 3.786 ms | 3.277 ms | 16% |

Reproduce in native PowerShell (set `$godot` to the engine executable):

```powershell
$env:GRAFFITTY_2D_ARTIFACTS = "$PWD/shots/flat-2d"
& $godot --path frontends/godot/project --script tests/flat_2d_smoke.gd -- --no-fx --no-focus-skip --shell=pwsh.exe
& $godot --path frontends/godot/project --script tools/benchmark_flat_2d.gd -- --no-fx --no-focus-skip --no-tabfx --shell=pwsh.exe
```

The smoke test checks screenshot parity, persistent sessions, 2D input projection,
real typing events, zoom/pan, multiple panes, tab switching, particles and restoration
to Flat, and fails on engine/script/shader errors. It writes screenshots and
`parity.json`. The benchmark writes individual samples and hardware metadata to
`benchmark.json`; frame p95, draw calls and reported video memory are included.
Raw measurements are also saved in [flat-2d-windows.json](../../benchmarks/flat-2d-windows.json).
