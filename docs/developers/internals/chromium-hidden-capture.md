# Hidden browser capture

Embedded pages must deliver GPU frames without showing or activating a native window.
Moving a window offscreen or briefly showing it during startup does not meet that requirement.

## Current implementation

- The pinned CEF patch preserves hidden-window creation.
- Compositor visibility is independent of native-window presentation.
- The host rejects unsolicited embedded focus.
- Capture leases release safely during renderer teardown.

Build using [CEF on macOS](../build-and-run/cef-build.md).
The canonical patches live in `fork/cef/`.

## Recorded verification

The October 1 source rebuild passed capture, resize, resource-monitor, and profile
smoke tests, including GPU frame delivery and no unexpected native window orders,
key events, or activation. A complete cold bootstrap was not executed.

## Detailed evidence

[Hidden browser capture — source notes and results](chromium-hidden-capture-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
