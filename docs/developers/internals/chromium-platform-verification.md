# Chromium verification backlog

Track remaining coverage separately from bounded passes.
Start with [acceptance status](chromium-acceptance-checklist.md) for report links.

## Established in the recorded runs

- Android host/backend workflow matrix: **32/32 final cases passed**.
- Rebuilt macOS resize path: three Alloy and two Chrome runs passed.
- Shared short stress suites passed across all three desktop OSes.
- Native checkpoint and GPU-recovery checks cover their listed cases only.

## Still needs evidence

- Later macOS throughput/startup failures.
- Linux eight-hour cgroup-growth failure and the pending instrumented rerun.
- Multi-hour native GPU accounting and actual macOS/Windows encoder exhaustion.
- Mixed backing scale, cross-adapter presentation, and additional hardware.
- Full native desktop workflows beyond the tested host/API paths.

Retain the original failures and artifact hashes when adding results. Existing
binary evidence cannot certify an unbuilt source tree.

## Detailed evidence

[Chromium verification backlog — source notes and results](chromium-platform-verification-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
