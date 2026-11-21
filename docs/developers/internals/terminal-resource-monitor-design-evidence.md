# Resource accounting design record

This is design rationale, not a second configuration/API schema.
Use [current API](resource-monitor-api.md) and [backend status](resource-monitor-backends.md)
for implemented behavior. Detailed accounting and Darwin peak bounds remain proposals.

## Purpose and sampling

Provide current CPU/memory, observed CPU time, and meaningful coverage at low cost.
The default terminal cadence is five seconds; sampling and UI repaint are independent.
Pause preserves history and marks a gap. Resume revalidates membership and starts
a new CPU epoch; disable/enable and reset have their own history semantics.
No exact per-command profiling, transient-memory capture, or cross-platform I/O is promised.

## Cross-platform behavior summary

| Platform | Boundary | CPU | Memory |
| --- | --- | --- | --- |
| Linux | cgroup v2 before shell execution | cpu.stat cumulative workload counters | memory.current / memory.peak |
| Windows | Job Object before child execution | TotalUserTime / TotalKernelTime, including exited processes | Job-level committed memory and kernel peak |
| macOS | Sticky (PID,start_abstime) discovered descendants | Living frontier self + reaped-child counters | Sum physical footprint; observed peak |

Preserve normal PTY sessions/PGIDs. Delegation and nested jobs need runtime tests.
Memory semantics are not byte-for-byte equivalent across platforms.

## macOS CPU accounting

Ancestry discovers membership; later reparenting does not erase an identified member.
Validate PID/start time, not PID alone.

```text
CPU = sum over the living tracked frontier of
      ri_user_time + ri_system_time + ri_child_user_time + ri_child_system_time
rate_one_core = delta(CPU) / delta(wall_time) * 100
```

Child counters contain directly reaped CPU. A still-living grandparent does not
already contain the intermediate process's child total. On reap, self+child CPU
transfers upward. This partitions normally reaped work without transitive double counting.
Convert Darwin absolute-time fields with mach_timebase_info; validate per architecture.
UI default all-core scaling is applied separately by the current implementation.

## macOS memory accounting

Sum living `ri_phys_footprint`; dead processes contribute no current memory.
Do not substitute summed RSS, which overcounts shared mappings.
Observed peak is the maximum sampled aggregate and can miss between-sample spikes.

### Proposed overlap upper bound

A simple sum of lifetime maxima overcounts staggered tasks: four nonoverlapping
150 MB processes do not imply a concurrent 600 MB workload.

```text
upper_peak = max over time t of
             sum(lifetime_max_i for discovered processes alive at t)
```

A start/death sweep adds/subtracts each maximum. This bounds only the discovered
set, assumes overlapping maxima coincide, and is not currently exposed as an
implemented value. Unknown short-lived processes remain outside the bound.

## Rejected alternatives

| Mechanism | Why it is not the primary boundary |
| --- | --- |
| SID | Descendants can setsid and leave it |
| PGID | Job control deliberately creates different groups |
| Coalitions | Ordinary terminals cannot create arbitrary private coalitions |
| EndpointSecurity | Privileged deployment/entitlements |
| DYLD injection | Intrusive and restricted |
| Environment tag | Can be removed; existing daemons do not inherit it |
| kqueue lifecycle events | Deferred for detailed inventory, not required for basic reaped CPU |

## Gaps and proposals

macOS child I/O does not transfer to parent counters on reap, so polling cannot
provide a reliable cumulative workload I/O total. wait4(shell) is a cross-check,
not unconditional ground truth for orphaned descendants.

Resume rediscovers descendants, reconciles sticky identities, validates start times,
resets the current baseline, and marks a new epoch. Memory spikes and unknown
spawn/detach/exit activity during the gap cannot be reconstructed.

Future work includes history, coverage diagnostics, discovered-set peak bounds,
and opt-in kqueue per-command/orphan/I/O detail. No proposed CLI names or
`detailed_accounting` option should be treated as installed features.

## Tests

Validate nested/parallel CPU, short-lived children, jobs/pipelines, setsid and
reparenting, PID reuse, memory allocation/overlap/staggering, pause/resume/reset,
interval changes, and root exit with descendants.
Darwin-specific checks must establish frontier conservation, no double counting,
identity persistence, I/O nontransfer, orphan wait4 limits, and peak-bound scope.
