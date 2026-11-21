# Android agent workload

The October 23 continuation improved deterministic six-PTY workloads, but six
simultaneous real-agent responses still exceeded the **50 ms P95** target.

## Final measurements to use

| Workload | Main-loop P95 |
| --- | ---: |
| Six PTYs with animated titles | 46.123 ms |
| Six PTYs with colored Unicode scrolling | 47.502 ms |
| Six simultaneous real-agent responses | 55.552 ms |
| One response with five other CLIs open | 26.336 ms |
| Idle pane navigation | 29.502 ms |

These are main-loop intervals, not display FPS or statistical latency guarantees.
Deterministic passes do not certify the worst-case real-agent workload.

## Changes behind the result

Credit/backlog handling bounds delivery; visible repaint assertions prevent reduced
updates from masquerading as smoothness. Layout-claim and keyboard-ownership
regressions were checked separately. The regular APK saved-connection reconnect
also passed in the recorded run.

## Detailed evidence

[Android agent workload — source notes and results](android-agent-workload-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
