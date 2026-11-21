# Chromium acceptance status

Check each platform, backend, and frontend separately. A native-host pass does not
establish Godot, Android, IME, or long-duration acceptance.

## Read the current result

| Area | Report |
| --- | --- |
| Android workflows against macOS/Windows hosts | [Desktop-host matrix](desktop-chromium-e2e.md) |
| Mixed viewers and bounded pressure | [Platform stress](chromium-platform-stress.md) |
| Outstanding platform coverage | [Verification backlog](chromium-platform-verification.md) |
| Linux frontend and cleanup | [Linux frontend](linux-chromium-frontend.md) |

The Linux eight-hour run failed its X11 Alloy cgroup-growth limit. A later short
pass does not replace that failure. The instrumented eight-hour rerun was still
pending in the recorded evidence.

## Record a result

Keep artifact/source hashes, the exact environment, assertions, failures, and cleanup.
Mark missing environments as untested. Do not promote a replay marker to a pass
when shutdown or cleanup failed.

## Detailed evidence

[Chromium acceptance status — source notes and results](chromium-acceptance-checklist-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
