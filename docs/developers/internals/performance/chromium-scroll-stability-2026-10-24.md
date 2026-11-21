# Chromium scroll and recovery investigation

This record contains several successive fixes. Use its final conclusions rather
than treating each earlier observation as current behavior.

## Findings to keep

- Server Mach-message send failures leaked returned frame rights. Both senders now
  destroy the returned message; a stopped-reader regression checks port counts.
- Browser tab IDs now follow CDP page targets instead of positions, preserving
  selection and confirming drag order promptly.
- Concurrent Restart requests treat an already relaunching browser as restarted.
- Deliberate crash tests caused macOS crash dialogs; the normal test path now uses
  owned-process SIGKILL and checks that it created no crash report.

## Limits

Detached-window restart and unwritable-profile behavior were not covered.
Component/security updates remain enabled. CEF media/DRM limitations and the
reported website-detection observations apply to the recorded build.

Use [the current streaming contract](chromium-streaming.md) for implementation
boundaries and this evidence for the dated investigation.

## Detailed evidence

[Chromium scroll and recovery investigation — source notes and results](chromium-scroll-stability-2026-10-24-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
