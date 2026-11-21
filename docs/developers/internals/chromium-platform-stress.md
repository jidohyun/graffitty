# Chromium platform stress

The bounded suites passed on macOS, Windows, and Linux with Chrome and Alloy.
**The separate Linux eight-hour endurance run failed.**

## What passed

- Mixed codecs, slow/stalled viewers, connection churn, and resize recovery.
- Short resource sampling and owned-process cleanup.
- Linux admission errors followed by successful recovery after capacity release.

The six-viewer macOS/Windows tests did not exhaust their encoder pools.
Short runs do not establish indefinite memory stability or native GPU reclamation.

## Longer macOS follow-up

The November 2 900-second follow-up failed both cases: Chrome missed throughput
requirements; Alloy timed out before browser-ready. Both fixtures cleaned up.
Earlier bounded passes remain valid only for their own runs.

## What remains unresolved

X11 Alloy's eight-hour browser-cgroup growth was **486.3 MiB**, above the **256 MiB** limit.
The failure prevented final decoding and the final GPU-reclamation assertion.

The instrumented rerun correlated later file-cache growth with a model-component
download. It had not completed in this record, and it does not prove the old
failure's cause. The original growth limit remains unchanged.

## Run the suite

Use `tests/chromium/test_chromium_platform_stress.py` with an explicit platform and owned
server/host paths. Run pressure and endurance workloads separately on the same GPU.
Full commands and assertion thresholds are in the evidence.

## Detailed evidence

[Chromium platform stress — source notes and results](chromium-platform-stress-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
