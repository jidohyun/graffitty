# Chromium stress run records

Recorded evidence; these results apply to the named runs and artifacts.

## Run verdicts

| Run | Verdict | Evidence boundary |
| --- | --- | --- |
| Nov 1 short suites, all three OSes/both backends | Pass | Twelve reconnects, eight resizes, bounded pressure/soak |
| Linux eight-hour, four configurations | Fail | X11 Alloy cgroup growth 486.3 MiB exceeded 256 MiB |
| Linux ten-minute diagnostic | Pass | Does not explain old eight-hour growth |
| Instrumented Linux eight-hour rerun | Pending | Six-hour observations are progress, not acceptance |
| Nov 2 macOS Chrome, requested 900 s | Fail | 127 throughput windows below 70% baseline |
| Nov 2 macOS Alloy | Fail | Browser-ready timeout; soak never ran |

### Short-suite limits

macOS/Windows sampled 122–124 seconds and did not exhaust six-viewer encoder pools.
Linux sampled 94–95 seconds and returned explicit codec-unavailable responses
at the fourth delayed viewer. It ran beside endurance fixtures: not idle-GPU throughput.
Linux median server RSS growth was zero, child RSS −1.00–3.17 MiB, descriptors 0–1.
Across reported runs, RSS/child growth was 0–0.68 / −0.20–24.62 MiB, descriptors 0–3.
Sixteen Rust video tests and both macOS native suites passed.

### Eight-hour failure and follow-up

All four configurations reached 960 samples; last sample 28,770 s.
X11 Alloy peaked at 4.47 GiB, with server RSS +2.93 MiB and no median
GPU/descriptor growth. All cleanup records exited 0 without cgroup leaks.
The failure prevented its final decode and GPU-reclamation assertion.

New sampling adds memory.stat/events, smaps_rollup, and component storage.
`shmem` belongs within `file`, not an additive charge. Initial diagnostics found
~870 MiB file cache and ~875 MiB downloaded components per browser.
The ten-minute X11 run had 120 samples, total-charge changes −0.6/−2.1 MiB,
16 KiB file growth, decoded video, and clean teardown.

At six hours, X11 Chrome grew ~1,432 MiB (file ~1,387; kernel 44; anonymous −0.6).
All streamed ~14.6 FPS with no recorded OOM. At 18,210 s all profiles reported
a 2,730 MiB OptGuideOnDeviceModel after earlier cgroup peaks.
This is correlation, not proof of the old failure's cause. Limits/security
updates remain unchanged. Final decode and cleanup are attempted even on limit failure.

### Longer macOS follow-up

Chrome: 904 s/171 samples, baseline 49.98 FPS, minimum 5.80, longest gap 1.47 s;
RSS −0.14 MiB, children +42.41 MiB, descriptors unchanged; final 60 frames changed.
Alloy timed out before ready. Both fixtures cleaned up; later desktop-load
observations do not establish either root cause.

## Acceptance rules

Baseline ≥20 FPS; healthy viewers ≥70% baseline and ≥10 FPS, gaps <2 s.
Growth limits: server 128 MiB, summed children 256 MiB, descriptors/handles 32.
Summed RSS is not GPU accounting. Actual exhaustion requires an observed error.
Resource/decoder failures remain failures; three units preserve those limits.

## Scheduling correction

Shared renditions run first; private renditions run least-recently-encoded first
with a 16.667 ms budget. Deferred work retains references/keyframe requests.
Windows resize checks use actual native DPI. Samplers preserve process identity
and fail missing live-process metrics rather than counting zero.

Run isolated pressure tests separately from endurance on the same GPU.
Windows needs an interactive principal and psutil; all drivers need FFmpeg.
These are local-capability streaming checks, not remote login or native input acceptance.

## Recorded measurements

### Results — 2026-11-01

| Platform/backend | Final suite | Baseline fps | Viewer-pressure fps (up to six) |
| --- | --- | --- | --- |
| macOS Chrome | Pass | 50.0 | 48.5 |
| macOS Alloy | Pass | 49.9 | 51.3 |
| Windows Chrome | Pass | 48.9 | 50.2 |
| Windows Alloy | Pass | 48.6 | 51.3 |
| Linux Wayland Chrome | Pass | 38.2 | 38.7 |
| Linux Wayland Alloy | Pass | 35.0 | 38.9 |
| Linux X11 Chrome | Pass | 35.6 | 39.0 |
| Linux X11 Alloy | Pass | 34.2 | 39.4 |

### Running the suites

| Check | Assertion |
| --- | --- |
| Baseline | Hardware video at least 20 fps; 60 sampled frames decode into changing images |
| Mixed codecs and slow viewer | H.264 rendition at most 360 pixels high, throttled/delayed peer decodes, healthy peer stays responsive |
| Stalled viewer | Viewer stops reading entirely, healthy peer continues, original connection resumes and decodes |
| Bounded encoder pressure | Up to six delayed viewers get video or an explicit error; healthy peer retains throughput; a fresh rendition decodes after release |
| Churn | Twelve fresh connections alternate codec requests, decode fresh frames, then disconnect |
| Resize | Eight alternating CSS sizes replace encoder generations while respecting measured capture DPI; final frames decode |
| Bounded soak | Document identity and video remain live; server RSS, descendant RSS and file descriptors/handles are sampled; final frames decode |
| Cleanup | No surviving owned descendants; normal server exit on Unix, explicitly forced process-tree shutdown on Windows |

## Commands and examples

### Running the suites

```sh
uv run tests/chromium/test_chromium_platform_stress.py \
  --platform macos --server /path/to/gft --host /path/to/host.app/Contents/MacOS/probe \
  --shell /bin/sh --artifacts .cache/platform-stress/macos

uv run tests/chromium/test_chromium_platform_stress.py \
  --platform linux --ozone wayland \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --shell /bin/sh --artifacts .cache/platform-stress/wayland

uv run tests/chromium/test_chromium_platform_stress.py \
  --platform windows --ssh windows-test-host \
  --server C:/test/gft.exe --host C:/test/cef/graffitty_chromium.exe \
  --shell 'C:/Program Files/Git/bin/bash.exe' --python C:/test/python.exe \
  --remote-dir C:/test/stress --principal-task ExistingInteractiveTestTask \
  --artifacts .cache/platform-stress/windows
```

## Evidence files

- `.cache/mac-alloy-resize/stress-scheduler-final`
- `.cache/chromium-acceptance/linux-endurance-8h`
- `.cache/chromium-acceptance/linux-memory-6h-snapshot`
- `.cache/linux-memory-followup`
- `.cache/chromium-acceptance/linux-memory-*`
- `.cache/chromium-platform-stress`
- `.cache/chromium-acceptance/linux-portable-current-stress-{wayland,x11}`
- `.cache/chromium-acceptance/mac-stress-15m-per-backend`
