# Resource monitor backends

Memory means different things on each OS. Preserve `memory_label`, status,
coverage gaps, and sample validity when presenting measurements.

## Backend status and limits

| Platform | Membership | Memory | CPU |
| --- | --- | --- | --- |
| macOS | Sticky PID/start-time descendants | Physical footprint | Self + reaped-child frontier |
| Linux | Private cgroup v2 | `memory.current`; kernel peak where available | Kernel aggregate |
| Windows | Job Object per ConPTY | Job committed bytes and lifetime peak | Includes exited descendants |

### macOS

Use `proc_pid_rusage(RUSAGE_INFO_V4)` and targeted `proc_listchildpids`, not a
system-wide metric sweep. Validate PID/start_abstime and convert Mach timebase.
Bounded frontier retries handle concurrent reap. Zombie CPU remains until reap;
zombie memory is zero. Lost counters, identity reuse, or permissions mark gaps.

Unseen children can escape discovery; reaped-child CPU usually survives, memory
peaks do not. Exiting orphans may lose final CPU increments. No exact wait4
close-out, full lifecycle trace, aggregate I/O, or undiscovered-memory bound is claimed.

### Linux

A `/bin/sh` bootstrap joins the private cgroup before shell exec without changing
PGIDs. Require delegated CPU/memory controllers; optionally set
`GODOT_RESOURCE_CGROUP_PARENT`. Missing delegation reports unavailable without
blocking terminal use. No root escalation, controller modification, or RSS fallback.
Remove only empty groups; survivors retain their group.

### Windows

Assign the job atomically with `PROC_THREAD_ATTRIBUTE_JOB_LIST` before user code.
Descendants remain members after root exit. Failure to create/assign the job
fails PTY launch rather than running unaccounted work.

Read `JobObjectMemoryUsageInformation` class 28. Rejection reports unavailable;
limit-violation notifications are not current memory. No memory limits,
breakaway, or kill-on-close policies are installed.
Rows show private commit and creation identity where accessible; parent PID is
currently zero. Churn can make inventory/counters temporarily disagree.
Retain kernel commit readings after exit instead of forcing zero.

## Validation

### Browser adapter

```sh
godot --headless --path frontends/godot/project --script tests/run.gd -- chromium_resource_monitor
godot --path frontends/godot/project --script tests/chromium_resource_monitor_smoke.gd -- --shell=/bin/sh
# Add --benchmark after -- for the macOS idle off/on/paused CPU comparison.
```

Live browser checks were exercised on macOS; Windows browser-host integration
still needs its own runtime check. Idle browser CPU includes more than sampler cost.

### Native workload accounting

```sh
cd crates/platform/resource-monitor
cargo test
```

```powershell
cargo test --manifest-path crates/platform/resource-monitor/Cargo.toml
cargo check --manifest-path frontends/godot/extension/Cargo.toml
```

Recorded Windows build `10.0.26200.9278`: four integration and three shared unit
tests passed; extension cargo check passed with Rust 1.94.0/Zig 0.15.2.
Coverage includes commit/release/peak, exited-child CPU, isolation, nested jobs,
surviving descendants, pause/resume/reset/removal, and invalid post-spawn PIDs.
It does not certify every Windows version or parent-job policy.

Native fixtures also cover nested/parallel CPU, reaped-child conservation,
setsid/reparenting, PID identity, and memory allocation. Linux parser/build checks
alone are not PTY runtime acceptance.

## Overhead

Collection runs off the render thread and stops while paused/disabled.
Only latest inventory is retained. Reproduce the sampler-only macOS comparison:

```sh
cd crates/platform/resource-monitor
cargo run --release --example overhead -- 20 5 20
cargo run --release --example overhead -- 20 0 10 # disabled
/usr/bin/time -l target/release/examples/overhead 20 5 10
```

| M1 Max, 20 one-process workloads | Recorded value |
| --- | --- |
| Five-second sampling | 0.03–0.05% of one core |
| Disabled | Zero samples; about 0.0001% CPU |
| Peak footprint | 1.25 MiB versus 1.00 MiB with no workloads |

Separate-run footprint is not a precise allocation delta. These small workloads
do not certify huge trees or rapid sampling; keep the five-second terminal default.
