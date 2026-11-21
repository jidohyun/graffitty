# Resource monitor design

Use native workload accounting rather than treating a terminal's shell PID as the whole workload.

## Accounting model

| Platform | Boundary | Memory meaning |
| --- | --- | --- |
| Linux | Private cgroup v2 | Cgroup charge |
| Windows | Job Object | Committed bytes |
| macOS | Sticky PID/start-time identities | Physical footprint |

CPU counters and memory semantics differ across platforms. Pause/resume must expose
coverage gaps; errors must remain unavailable rather than becoming zero.

## Implementation versus proposal

Use [Resource monitor API](resource-monitor-api.md) and
[backend status](resource-monitor-backends.md) for implemented behavior.
The source design includes proposed commands, detailed accounting, and macOS peak
bounds. Those proposals are not available settings or completed features.

## Detailed evidence

[Resource monitor design — source notes and results](terminal-resource-monitor-design-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
