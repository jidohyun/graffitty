# Android workload run records

Recorded evidence; these results apply to the named runs and artifacts.

## Latest result — October 23

Deterministic six-PTY workloads passed P95 <50 ms / max <500 ms, with visible
repaint minimums (20 title /40 scroll) and all 240 title updates received.
Six simultaneous real-agent responses still missed 50 ms P95; one response and
idle navigation passed. Tables retain the exact measurements and earlier runs.
Main-loop intervals are not display FPS or statistical latency guarantees.

## Changes and invariants

- Bound owner/client credit and backlog while retaining final state and exactly-once input.
- Reuse render targets during pane fitting; reversal/gesture interruption still checks geometry.
- Avoid closed-keyboard tree scans and coalesce tab refresh within a frame.
- Settle acknowledged layout claims before deciding resize ownership; invalidate signatures on canonical changes.
- Guard absent Linux frame metadata during Android startup.

## Recorded verification

Three Rust backlog/credit tests, seven live owner protocol tests, and five
owner-to-renderer tests ran with three platform/GPU skips. Twelve layout-claim
regressions and the 120-check physical keyboard ownership scenario passed.
Protocol checks cover forged ACKs, packet/byte bounds, delta retention, checkpoints,
and exactly-once input.

Two Claude, two Codex, and two Pi sessions completed bounded prompts and later
reported integration enabled/idle. Codex needed carriage return; the previous
CSI Enter had not submitted. Startup/idle time is included in captures.

## Deployment boundary

The regular APK saved-connection restart/reconnect passed after removing the
one-time seed. Android input reached the intended pane and was cleared without
submission. No Godot errors were recorded. The disposable benchmark APK was
removed; the Mac installed app was not replaced.
The isolated updated owner and artifacts—not every production component—define
this run's scope. Original startup/performance failures remain in the evidence.

## Recorded measurements

### Workload and measurements

| Valid capture | Duration | Mean | P95 | P99 | Maximum | >50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Warm idle, populated workspace | 30 s | 16.67 ms | 17.27 ms | 17.84 ms | 20.08 ms | 0 |
| Settled navigation, before fit fix | 30 s | 17.33 ms | 18.28 ms | 47.08 ms | 135.73 ms | 14 |
| Settled navigation, after fit fix | 30 s | 17.07 ms | 17.22 ms | 40.10 ms | 94.88 ms | 10 |
| Manager, six agents streaming in overview | 30 s | 17.90 ms | 30.98 ms | 42.35 ms | 83.17 ms | 13 |

### Tablet follow-up

| Capture before tablet fixes | Mean | P95 | P99 | Maximum | >50 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Six idle panes, overview, 30 s | 16.74 ms | 17.69 ms | 28.82 ms | 82.81 ms | 1 |
| Six agents producing tables/code, 30 s | 50.09 ms | 89.28 ms | 102.34 ms | 180.20 ms | 284 |
| Pane navigation, 30 s | 19.13 ms | 33.85 ms | 88.53 ms | 162.10 ms | 56 |

### October 22 tablet verification

| Final deterministic workload | P95 | P99 | Maximum |
| --- | ---: | ---: | ---: |
| Six PTYs, colored Unicode scrolling | 55.668 ms | 80.280 ms | 196.969 ms |
| Six PTYs, output plus animated titles | 58.371 ms | 72.042 ms | 203.902 ms |

### Real-agent performance and fixes

| Valid real-agent capture | Duration | Mean | P95 | P99 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| Six simultaneous responses, before topology fixes | 30 s | 86.031 ms | 103.894 ms | 113.742 ms | 126.657 ms |
| Six simultaneous responses, final overview | 30 s | 27.013 ms | 52.175 ms | 66.645 ms | 235.432 ms |
| One Claude response, five other CLIs open, final focus | 30 s | 17.807 ms | 27.539 ms | 56.004 ms | 125.842 ms |
| Scripted pane navigation, agents idle | 30 s | 19.261 ms | 30.192 ms | 90.179 ms | 178.752 ms |

### October 23 continuation on the tablet

| Unrecorded deterministic workload, eight packets | P95 | P99 | Maximum | Repaints per pane |
| --- | ---: | ---: | ---: | ---: |
| Six PTYs with animated titles | 46.123 ms | 64.051 ms | 138.280 ms | 24–26 |
| Six PTYs with colored Unicode scrolling | 47.502 ms | 67.093 ms | 160.650 ms | 81–83 |

### Fresh real-agent verification

| Unrecorded real-agent capture, 30 s | Mean | P95 | P99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Six simultaneous responses in overview | 36.857 ms | 55.552 ms | 67.795 ms | 118.983 ms |
| One Claude response, five other CLIs open | 17.991 ms | 26.336 ms | 55.870 ms | 129.968 ms |
| Idle pane navigation | 19.037 ms | 29.502 ms | 79.476 ms | 209.755 ms |

## Evidence files

- `build/android-agent-perf/`
- `build/android/e2e/20261022-201624/`
- `build/android-tablet-perf/`
- `build/android-tablet-perf/e2e-updated/`
- `build/android-tablet-perf/combined-results.json`
