# Windows host → macOS desktop-client validation

## Exercised

- Built the Lumen Windows host and Web UI using the native MSYS2 UCRT64 toolchain.
- Installed in the per-user Programs/Lumen location with separate configuration,
  credentials, pairing state, and an interactive scheduled task.
- Kept Apollo stopped with manual startup; its installation/configuration remain intact.
- Paired the Moonlight Office Mac build through the authenticated PIN flow.
- Started a 1920x1080, 60 FPS, H.264 SDR stream to a client-sized SudoVDA display.
- Host log confirmed virtual-display creation and NVIDIA hardware encoding.
- Client log confirmed VideoToolbox decoding; a captured client-window image showed
  the actual Windows desktop. Private images/logs remain outside the repository.
- Native macOS window metadata confirmed a normal window and floating-control
  opacity of 0.1.
- Terminated the client process to test abrupt disconnect; the host reported client
  disconnection and encoder teardown, remained alive, and accepted a reconnect.

## Findings / limits

- Initial launch took approximately nine seconds to video startup. The Windows
  encoder capability probe accounted for roughly three seconds of that run.
- Reconnect recreated the virtual output and probed again. This is not evidence of
  an unchanged-topology cache hit, nor of reduced startup time on macOS.
- The Mac's installed Lumen has not yet been replaced with the capability-cache build.
- The automation process lacks macOS Accessibility permission. Real clicks, held
  drag/reposition, fullscreen transitions, opening settings, and disconnect-button
  behavior remain **not live-E2E verified**. The separate SDL control smoke checks
  are not a substitute for these tests.
- Abrupt client termination does not validate the Disconnect button and is not an
  assertion that the host app quit or that its virtual display was removed.
- Windows-to-Android regression coverage is still separate and outstanding.
- Runtime input-event coverage, display cleanup on application quit, watchdog
  failure recovery, and stable monitor identity across full host restarts remain
  outstanding. Do not mark the entire Windows port complete from this stream test.
