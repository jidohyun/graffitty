# Linux Chromium lifecycle results

The recorded final two-hour run passed all four configurations:
Chrome/Alloy on Wayland/X11, with **240 samples per configuration**.

## What passed

- Fourteen short runs covered capacity, startup pressure, reconnect, and churn.
- Final samples decoded 60 changing frames; the lowest measured rate was 14.40 FPS.
- Servers exited cleanly; owned GPU memory and encoder sessions returned to zero.

These are bounded measurements. They do not establish arbitrary-duration leak
freedom, physical GPU-reset recovery, other compositors/vendors, or ARM64.
The later [eight-hour stress failure](chromium-platform-stress.md) remains separate.

## Reproduce

Use `tests/platform/linux/linux_chromium_lifecycle_e2e.py` with an owned server, host, backend,
platform, and fresh output directory. Full arguments and resource deltas are
in the evidence.

## Detailed evidence

[Linux Chromium lifecycle results — source notes and results](linux-chromium-lifecycle-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
