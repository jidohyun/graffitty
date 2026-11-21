# Linux Chromium stress results

The recorded fixed-server runs passed twelve additional suite/backend results
and **35 selected server tests**. The four final owned fixtures cleaned up.

## Scope of the pass

| Environment | Recorded coverage |
| --- | --- |
| Wayland, Chrome/Alloy | Ten-minute soaks, slow/stalled viewers, decoding, network impairment, recovery |
| X11, Chrome/Alloy | Multi-client delivery, owned GPU-process termination, encoder recreation, decoding |

X11 skipped the ten-minute soak. Owned GPU-process termination is not a physical
GPU reset. Earlier failed attempts remain in the evidence.

## Run safely within the harness

Use the disposable fixtures and private network namespace described in the evidence.
They own their servers and do not impair the host's normal network.

For longer runs, see [lifecycle results](linux-chromium-lifecycle.md) and
[platform stress](chromium-platform-stress.md), including the eight-hour failure.

## Detailed evidence

[Linux Chromium stress results — source notes and results](linux-chromium-stress-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
