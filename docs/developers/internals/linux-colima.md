# Linux GUI testing in Colima

The recorded run used native ARM64 Linux binaries and llvmpipe software rendering
inside an isolated Colima environment. It was functional testing, not physical-GPU
or performance certification.

## Final catalog result

| Outcome | Cases |
| --- | ---: |
| Passed | 39 |
| Failed | 22 |
| Timed out | 8 |
| Blocked | 40 |
| Android simulations skipped | 31 |
| Platform-specific, not applicable | 56 |

All **196 entries** were classified. This is a completed run with unresolved failures.

## What to follow up

Transferred-pane input, creation/placement, scroll/zoom, and animation cases still
failed. Heavy world/effect cases timed out under software rendering.
Manual scenarios, providers, CEF, audio, and delegated statistics remained unverified
or blocked. No macOS or Windows acceptance follows from this run.

## Detailed evidence

[Linux GUI testing in Colima — source notes and results](linux-colima-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
