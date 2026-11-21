# Render-cost measurements

Recorded **2026-10-08**, M1 Max/Godot 4.7.2. Lower DoF quality, unshadowed
accents, and motion scaling reduced the isolated harness from **43.3 to 12.4 ms**.
The real 2560×1440 host improved from **32.4 to 22 ms**.

## Recorded result — 2026-10-08

| | typing frame, harness |
| --- | --- |
| before | 43.3 ms |
| DoF quality 1 (`project.godot`) and unshadowed accents | 26.4 ms |
| plus `motion_render_scale` 0.5 while the camera moves | 12.4 ms |

Motion scale 0.6 measured 16.7 ms; 0.55 measured 14.4 ms. Hiding scenery in the
real host still cost 19.4 ms, so terminal/compositor work remained significant.

## What was measured

The harness mirrored SceneryView: streamed scene, four sun cascades, 28 accents,
SSAO, sky, typing lens, MSAA 4×, 3840×2160 target at scale 0.8.
Metal GPU timestamps returned zero; these are uncapped frame times, not GPU timings.
CPU was about 0.5 ms. Baselines alternated three times and medians were compared.

| change, shipped baseline 37-41 ms | delta |
| --- | --- |
| typing DoF off | -13.6 ms, the same on an empty scene |
| DoF quality High -> Low | -11.3 ms |
| 28 accent lights removed | -14.1 ms |
| 28 accent lights unshadowed | -2.4 ms |
| MSAA off | -2.0 ms |
| SSAO off | about -1 ms |
| scenery hidden | -19.8 ms |

## Interpretation

| Finding | Evidence |
| --- | --- |
| Depth of field dominated | Full-resolution capped 32 px bokeh, quality-3 24-tap passes |
| Accents cost more than shadows | Removing lights saved 14.1 ms; removing shadows 2.4 ms |
| Shadow redraw could persist | Atlas-size mismatch failed to synchronize slot versions after changes |
| Geometry alone was cheap | Unshaded scene matched an empty frame |

The bokeh-shape setting had merged into a comment, leaving hexagonal shape.
Uniform atlas slot sizes avoid the observed perpetual shadow redraw (~2.45M triangles/frame).

## Method, and two ways of getting it wrong

- Use separate processes for pipeline/material changes; runtime specialization
  polluted one `nosky` measurement to 72 ms.
- Pair visibility-only changes inside one process using `--rt=ab_*`: 120 frames
  before/after. Thermal baseline drift was 44–68 ms across longer runs.
- Use `--rendertest --rt=CASE --fullscreen`; the tiling manager ignored resolution.

## Open

The recorded follow-ups were static-light baking, non-scenery profiling,
and per-world render settings.
The screen cap also multiplied already-pixel macOS screen size by scale.
These dated observations need fresh measurements before drawing current performance conclusions.
