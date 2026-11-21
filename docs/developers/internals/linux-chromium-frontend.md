# Linux Chromium frontend results

The final current-source four-case Godot video rerun passed **24 checks per case**,
process exit, and private-owner cleanup: Chrome/Alloy on Wayland/X11.

## What this establishes

The harness changes page content over CDP and samples the actual Godot viewport.
Wayland cases ran without `DISPLAY`. Further Wayland Alloy repetitions exited cleanly.

## Failures and gaps to retain

- An earlier Wayland Alloy run printed its assertion pass marker but hung on exit;
  that run remains failed and the intermittent hang is unresolved.
- Automated viewport checks do not establish physical keyboard, clipboard, IME,
  or window-manager behavior.
- Browser IME, remote file chooser/upload/download UI, and remote audio still lack
  the implemented paths needed for full frontend coverage.
- The separate eight-hour soak failed; see [platform stress](chromium-platform-stress.md).

## Detailed evidence

[Linux Chromium frontend results — source notes and results](linux-chromium-frontend-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
