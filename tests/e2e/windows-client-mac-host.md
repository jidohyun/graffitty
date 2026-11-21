# Windows Moonlight client → macOS Lumen host

This is distinct from the reverse direction in `windows-desktop-validation.md`.
Never infer Windows UI behavior from macOS client tests.

## Verified live (Windows Moonlight Office build → installed Mac Lumen)

- Built with MSVC + Qt 6.8.3; deployed per-user with Qt, prebuilt Moonlight, MSVC
  runtime, and `AntiHooking.dll` (missing it fails startup with
  `STATUS_DLL_NOT_FOUND` and produces no pairing request).
- Authenticated PIN pairing through the Lumen Web UI. An unpaired host record left
  by a failed attempt made the next CLI pairing stall; remove only the test
  client's stale host record, never server credentials.
- Windowed Desktop stream, D3D11VA decoding, video filling the 16:9 client area.
- Floating control: 24 px, 10% idle / 30% hover, verified over the stream and a
  blue fixture. Short click toggles the vertical menu; a held drag (450 ms) moved
  the button into the bottom-left without opening the menu. Position persisted
  across client restart. Near the bottom edge the menu opened above the button and
  stayed inside the client.
- Displays: menu listed the Mac's two actual displays (`1 | 2`), switching changed
  the video, and the highlight followed the host-confirmed selection.
- Disconnect: client tore down cleanly, host logged the disconnect, Lumen kept
  running, and reconnect worked.
- Local cursor stayed visible over the stream. Absolute positions matched within
  0.1% of the remote display at multiple targets, including clicks issued
  immediately after fast motion and drags in both directions.
- Keyboard (with real scan codes): Enter, Tab, Esc, Backspace, Delete, arrows,
  Home/End, Page Up/Down, Shift/Ctrl/Alt combinations arrived as the correct macOS
  keys with matching modifiers and no repeats.
- `mousemotion_test` and `sessioncontrols_smoke` pass on Windows and macOS.

## Bugs found and fixed by this test

- Windows: SDL3 transparent windows render empty and click-through, so the
  button was invisible and unclickable. Non-macOS builds use an ordinary window
  with whole-window alpha (logo and background share one alpha); macOS keeps
  per-pixel transparency.
- All platforms: menu Disconnect only set a startup flag and never ended a running
  stream. It now releases keys and posts the normal quit event.
- Mac host H.264 stutter (slice errors every ~4.1 s, ~3 frames dropped waiting
  for an IDR). Root cause, from a dump of the bitstream the Windows client
  decoded: clients without H.264 reference invalidation request one reference
  frame and Moonlight's SPS fixup rewrites `max_num_ref_frames` to 1, but
  VideoToolbox low-delay rate control (unset `max_ref_frames`) marked every IDR
  as a long-term reference and declared 4-5 references. Fix: H.264 VideoToolbox
  uses `max_ref_frames=2`. Offline at 1080p60 this keeps ~6 ms encode latency
  (disabling low-delay cost ~35 ms), produces no long-term references and no
  all-IDR output (which `max_ref_frames=1` causes), and after applying
  Moonlight's SPS fixup decodes 600 frames bit-identical to the original.
  Live after reinstall: 90 s with zero reference/slice/decode errors and no IDR
  waits (previously ~20 each). Re-check bitrate/latency on high-motion content.
- Defensive, separate: Lumen's own SPS rewrite (used only for encoders without
  VUI, so not VideoToolbox) no longer lowers `max_num_ref_frames` below the
  encoder's value (`CodedBitstreamH264.RewrittenSpsNeverUnderDeclaresEncoderReferences`).
- Cmd from Windows: system-key capture now defaults to always while the stream
  window has keyboard focus. Win+C/Win+V arrived as Cmd+C/Cmd+V and Command
  released; a lone Win press did not open the local Start menu. Ctrl stays Control.

## Test-tool pitfalls (not product bugs)

- `SetCursorPos` warps can lag SDL's motion state; use `SendInput`/`mouse_event`
  absolute moves when checking drag-release positions.
- `keybd_event` without a hardware scan code makes arrows appear as keypad keys.
  Supply `MapVirtualKey` scan codes and the extended flag, like a real keyboard.
- A Windows Defender Firewall prompt for the new client can sit invisibly over the
  desktop and swallow all clicks; dismiss it before UI tests.

## Outstanding

- Controlled-latency test of local cursor vs. remote click latency.
- Android check done (S20 FE, Exynos hardware decoders, Artemis Office, fixed
  host): auto/HEVC 90 s and forced H.264 ~90 s with continuous pointer motion.
  No IDR requests or reference invalidation, no host errors (including no
  "did not produce IDR"), visually clean frames. MediaCodec can hide corruption
  that FFmpeg would log, so keep the visual check. The external monitor was
  disconnected at the time; the host correctly published one display and the
  Artemis chooser showed only `1`. Re-test switching with two displays.
- Display switching with differing resolutions/DPI, minimize/restore, and resize.
- "Encoder did not produce IDR frame when requested" now appears once at session
  start instead of every few seconds. Offline, low-delay VideoToolbox returns a
  forced IDR in the same call, so investigate the startup case separately.
