# Latest-state terminal presentation

Recorded evidence; these results apply to the named runs and artifacts.

## Recorded outcome

Fifteen targeted tests passed. The isolated Android before/after pair delivered
final sequence 2400 in both runs and **did not establish a performance improvement**.
A broader client-core copy-mode color assertion remained failed.
The table retains exact metrics, not a 60 FPS or transport-latency claim.

## Boundaries

| Stage | Contract |
| --- | --- |
| Owner | Parse PTY bytes in order; projected backlog >64 KiB selects checkpoint at a valid control boundary |
| Transaction | May supersede obsolete unfinished delta; allow an in-progress snapshot to finish |
| Worker mailbox | Replace unconsumed pane commits with complete snapshot; fold safe same-size/limit deltas on worker |
| Credit | Preparation AND presentation delivery must finish; ≤128 KiB /8 packets outstanding |
| UI | ≤8 prepared items/poll; Godot handles≤2 ms; WebSocket yields after32 packets or2 ms |

No arbitrary packet drops, invalid delta bases, or truncated snapshots.
Resize/limit changes stay ordered when folding is unsafe. Assets/errors are
retained; errors force resynchronization. Mailbox capacity 32 uses producer
backpressure/shutdown wakeup; UI never waits on its lock.
Budgets are cooperative, not preemption of a large callback. Full-history
checkpoint cost still depends on scrollback; profile each stage independently.

## Tests

Mailbox cases collapse1000 revisions/pane to latest states, verify folded text,
independent assets/error boundaries, and shutdown unblock. Replay checks final
text plus separately delivered notifications/replies, not every transient frame.

## Android measurement

Use a disposable APK and dedicated owner, never active user sessions.
Profiler records scheduling/CPU/thermals without screen recording and restores
perf_harden. Foreground/PID changes invalidate intervals. Empty FrameTimeline
is not zero jank or measurable FPS.

SM-F966N exploration found VkThread19.39s scheduled CPU/20s and 40,221 stacks:
libc 54.61%, Godot 44.88%, extension 0.19% self cycles. App switching and missing
FrameTimeline prevent a controlled idle baseline or GPU utilization inference.

The valid synthetic before sequence ended before a later background sample;
do not label the entire monitoring period foreground-valid. Earlier switched-app,
ADB-timeout, orientation, and reused-workload attempts are excluded.
Final markers were sampled every250 ms, so ~250 ms differences do not prove latency.
Production Android/Windows binaries were not updated by this experiment.

## Recorded measurements

### Isolated device comparison (2026-10-22)

| Load phase | Before | After |
| --- | ---: | ---: |
| Mean frame interval | 16.70 ms | 16.72 ms |
| P95 frame interval | 28.98 ms | 29.45 ms |
| Maximum interval | 57.74 ms | 73.44 ms |
| Intervals above 33.33 ms | 2 | 2 |
| Final sequence | 2400 | 2400 |

## Commands and examples

### Tests

```sh
mise exec -- cargo test -p graffitty-client-core scene_mailbox --lib
mise exec -- cargo test -p graffitty-client-core scene_worker --lib
mise exec -- cargo test -p graffitty-client-core --test private_replay
mise exec -- cargo test -p graffitty-server terminal_scene::tests --lib
mise exec -- cargo check --locked --manifest-path frontends/godot/extension/Cargo.toml
```

### Android measurement

```sh
python3 tools/profile_android_terminal.py --serial SERIAL --seconds 20 \
  --cpu --output build/android-profile-before
# Repeat the same workload, foreground state, geometry, effects and connection
# after updating both test server and client, using a different output directory.
```

## Evidence files

- `build/android-latest-state/benchmark/`
