# Workspace physics measurements

Current solver measurements are separate from the historical all-pairs tests.
Both use an M1 Max and one-core CPU estimates; they are not matched-workload speedups.

## Current local-collision solver

A persistent512 px grid propagates contact chains; no browser springs/global attraction.
Idle disables physics callbacks until an edit. Sparse runs move one anchor against
one neighbor (others1000 px apart); dense runs overlap panes and move an anchor.
At128 panes, dense work averaged2272 pair checks/step.

| Panes | Sparse local drag, solver CPU | Dense cluster, solver CPU |
|---|---:|---:|
| 4 | 0.09% of one core | 0.15% |
| 12 | 0.13% | 0.49% |
| 24 | 0.18% | 1.79% |
| 64 | 0.39% | 7.17% |
| 128 | 0.69% | 29.16% |
| 512 | 2.80% | Not measured |

Values estimate solver CPU at 60 steps/s, excluding UI/rendering. Active index sync
still scans all rectangles; dense contact can approach quadratic work.
Reproduce with `tools/benchmark_workspace_physics.gd` through headless Godot.

## Previous all-pairs force solver

Historical **2026-09-27, Godot 4.7.2**. Retain these as earlier implementation data,
not current solver behavior.

### Full application

```sh
godot --path frontends/godot/project --script tools/benchmark_workspace_physics_app.gd -- --shell=/bin/sh --no-fx
```

Four three-second phases: off/sleeping/active/off,60 FPS, same small external move.
Process CPU excludes browser/child/GPU work. Final off retains the moved layout;
frames are not identical. Mean callbacks were182/426 µs active and66/125 µs sleeping
for4/12 panes. Sleeping still checked layout integration.

| Panes | Physics off (before / after) | Sleeping | Active | Approx. active overhead |
|---|---:|---:|---:|---:|
| 4 | 13.30% / 12.92% | 13.66% | 14.66% | +1.55 percentage points |
| 12 | 17.95% / 17.98% | 18.65% | 21.66% | +3.69 percentage points |

### Solver alone

```sh
godot --headless --path frontends/godot/project --script tools/benchmark_workspace_physics.gd
```

Ten 100-step batches, median step time. Active edits prevent sleeping; sleeping
uses early return. CPU estimates assume60 Hz and exclude integration/rendering.

| Panes | Active step | Estimated active share of one core | Sleeping step |
|---|---:|---:|---:|
| 4 | 13.72 µs | 0.08% | 0.53 µs |
| 12 | 76.56 µs | 0.46% | 0.76 µs |
| 24 | 254.89 µs | 1.53% | 1.00 µs |
| 64 | 1.74 ms | 10.42% | 1.88 µs |
| 128 | 6.48 ms | 38.89% | 3.37 µs |

Keep the Floating Pane Physics opt-out for large/dense layouts.
This measurement record itself changed no runtime behavior.
