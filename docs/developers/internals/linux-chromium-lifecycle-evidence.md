# Linux lifecycle run records

Recorded evidence; these results apply to the named runs and artifacts.

## Final recorded result

Fourteen short runs and all four final **two-hour** configurations passed.
The full run lasted 7,217 s including final decode, with 240 samples/configuration
and eight configuration-hours. Each final sample decoded 60 changing frames;
minimum rate was 14.40 FPS, largest gap 195 ms.

All servers exited without leaked cgroups; owned GPU memory and encoders returned
to zero. The coordinator completed 240 slow-viewer allocation/retirement cycles.
The table below records median post-warm-up resource changes.

## Short regressions

| Case | Required behavior |
| --- | --- |
| Capacity | Explicit exhaustion, healthy viewer ≥75% baseline, freed slots reusable without restarting |
| Startup capacity | Second server recovers when hardware slots free |
| Reconnect | Ten abrupt resets; fresh authenticated subscription/keyframe/decode, no private encoder retained |
| Churn | Twenty tab/resize/subscription cycles, correct page colors, retired descriptors/encoders |

Capacity probes up to sixteen slow viewers and fails if exhaustion was not exercised.
The first rendition retry fix and capability-cache correction were separate builds:
twelve base cases used the retry build; two startup cases/full endurance used the final build.
The final server passed 37 selected Chromium tests plus the cache regression.

## Failure corrections

An unavailable encoder allocation must be retried after capacity release. A partial
initial capability probe must not permanently cache an exhausted encoder as absent.
Deterministic cache tests passed Linux/macOS; real pressure recovery passed
Wayland/Chrome and X11/Alloy. Earlier failures remain in the artifacts.

## Scope

Two hours is not overnight or arbitrary-duration leak freedom. Physical GPU reset,
GNOME/KDE, fractional scale, other vendors, and ARM64 remain unverified.
The later eight-hour failure is tracked separately in the platform stress record.

## Recorded measurements

### Short regressions

| Case | Assertions |
| --- | --- |
| `capacity` | Congested viewers allocate private encoders until hardware capacity is actually reached; unsupported allocations report an explicit error; a healthy viewer retains 75% of baseline; resizing works with a full pool; an already-waiting viewer and a new viewer use freed capacity; encoder sessions retire after disconnect |
| `startup-capacity` | All capacity assertions, plus a second server started while the hardware pool is full; its existing viewer must recover without restarting that server when slots become free |
| `reconnect` | Ten abrupt TCP resets without WebSocket close handshakes; each new socket authenticates and subscribes afresh, starts with a keyframe, decodes the retained page, and leaves no private encoder behind |
| `churn` | Twenty cycles combining tab creation/closure, three queued resizes, subscription changes, and slow peers; final size settles; decoded color identifies the correct tab; unsubscribed tabs receive no further video; the anchor survives; encoder and descriptor counts return to baseline |

### Two-hour endurance

| Counter | Maximum permitted growth |
| --- | ---: |
| Server RSS | 128 MiB |
| Browser cgroup memory | 256 MiB |
| Owned GPU memory | 128 MiB |
| Server file descriptors | 4 |

### Results

| Median change after warm-up | Wayland Chrome | Wayland Alloy | X11 Chrome | X11 Alloy |
| --- | ---: | ---: | ---: | ---: |
| Server RSS | +0.30 MiB | +0.29 MiB | +0.48 MiB | +0.45 MiB |
| Browser cgroup memory | −18.32 MiB | −18.81 MiB | −17.37 MiB | −19.23 MiB |
| Owned GPU memory | −0.94 MiB | 0 MiB | 0 MiB | −1.88 MiB |
| Server file descriptors | 0 | 0 | 0 | 0 |

## Commands and examples

### Short regressions

```sh
uv run tests/platform/linux/linux_chromium_lifecycle_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --backend chrome --platform wayland --case capacity \
  --output .cache/linux-lifecycle/wayland-chrome-capacity
```

### Two-hour endurance

```sh
uv run tests/platform/linux/linux_chromium_endurance_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --seconds 7200 --output .cache/linux-endurance/run
```

### Two-hour endurance

```sh
uv run tests/platform/linux/linux_chromium_gpu_telemetry.py \
  --manifest /path/to/shared/run/manifest.json \
  --output /path/to/shared/run/gpu.json \
  --stop-file /path/to/shared/run/gpu-stop
```

## Evidence files

- `.cache/linux-stress/lifecycle-evidence.tar.gz`
- `.cache/linux-stress/verified-lifecycle-final.json`
