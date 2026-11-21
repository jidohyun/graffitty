# Resource monitor API

Subscribe to a monitor from a custom world. For app controls, see
[Resource Monitor](../../everyday-use/resource-monitor.md).

## World/plugin API

`host.resource_monitor_for(id)` accepts a terminal or successfully launched
browser session ID. The monitor survives world changes.

```gdscript
var monitor = host.resource_monitor_for(terminal_id)
monitor.snapshot_changed.connect(_on_resources)
_on_resources(monitor.snapshot())

func _on_resources(data: Dictionary) -> void:
    if data.get("status") != "running":
        my_label.text = data.get("status", "unavailable")
        return
    my_label.text = "%s: %.1f MiB" % [data.get("memory_label", "Memory"),
        float(data.memory_current) / 1048576.0]
```

Connect first, then read the snapshot.

## Methods and signals

| API | Purpose |
| --- | --- |
| `snapshot()` | Current dictionary |
| `set_enabled(bool)`, `set_interval(seconds)` | Configure collection |
| `pause()`, `resume()`, `reset()` | Control observation history |
| `snapshot_changed(Dictionary)` | New measurement |
| `state_changed(String)` | Lifecycle change |

Convenience properties: `cpu_percent`, `cpu_valid`, `cpu_time`, `memory_current`, `status`.

## Snapshot fields

| Fields | Meaning |
| --- | --- |
| `root_pid`, `backend`, `status`, `error`, `revision` | Workload and collection state |
| `cpu_percent`, `cpu_valid` | CPU rate; first sample establishes a baseline |
| `cpu_time_user`, `cpu_time_system`, `cpu_time` | Observed seconds, excluding pause/disabled gaps and pre-attachment time |
| `memory_current`, `memory_label` | Bytes and platform-specific meaning |
| `memory_peak_observed` | Largest sampled aggregate since reset |
| `memory_peak_kernel` | Native lifetime peak where available; does not reset |
| `memory_peak_upper_bound` | Null; proposed Darwin bounds are not implemented |
| `epoch`, `coverage_gap`, `sample_age_seconds`, `monitoring_seconds`, `sample_ms` | Observation coverage and timing |
| `process_count`, `processes` | Sampled inventory, not a spawn log |

Process rows contain pid/parent_pid/start_identity/name/memory_current.
Darwin memory is physical footprint. Linux row memory is unavailable (0);
never sum it to reconstruct cgroup memory.

### CPU scale

By default, **100% means all logical CPUs available to the server**.
`[resource_monitor] cpu_percent_scale = "one_core"` makes 100% one busy core.
Check `cpu_valid`: the first sample is not measured zero.

### Status

`starting`, `running`, `paused`, `disabled`, `exited`, or `unavailable`.
Errors retain an older stale sample; check status, age, and validity before display.
Missing/error measurements must not become zero.

## Configuration

In a preset passed with `--config=...`:

```ini
[resource_monitor]
enabled = true
interval = "5s"
```

Terminal intervals accept numbers/seconds or strings such as `250ms`;
range 0.1–3600 seconds, default 5 seconds. Browser collection uses 1 second.
Preview with `--resource-interval=1s`; disable with `--resource-monitor=off`.
Runtime changes do not restart shells.

| Action | History / collection |
| --- | --- |
| Pause | Stop discovery/sampling, retain history, mark a gap |
| Resume | Revalidate identities and establish a CPU baseline |
| Disable then enable | Reset observation history |
| Reset | Clear statistics, retain live identities |
| Close session | Unregister sampler; PTY teardown owns process lifetime |

## Delivery and browser collection

The server samples hidden terminals and sends cached values after attachment/topology,
then updates at one-second cadence. New processes need two CPU samples.
Hidden terminal viewports do not repaint merely for sampling.

Browser monitors include the host and descendants; tabs share one total.
They use the same native worker, without browser extensions. Pause/disable
removes registration; disconnected-client leases expire after ten seconds.
Root labels distinguish **Root shell PID** and **Chromium host PID**.

See [backend semantics and validation](resource-monitor-backends.md).
