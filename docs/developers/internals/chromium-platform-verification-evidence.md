# Chromium verification ledger

Recorded evidence; these results apply to the named runs and artifacts.

## Established coverage

| Area | Recorded result |
| --- | --- |
| macOS Alloy resize | Rebuilt-source reproduction, then 3 Alloy + 2 Chrome passes / 60 resizes |
| Android host matrix | 32/32 final scenarios across macOS/Windows × Chrome/Alloy |
| Native frontend input | Two runs per backend/OS passed after focus/edit-command fixes |
| GPU-child recovery | Ten macOS cycles per backend; native/display regressions passed |
| Two-window checkpoints | Native macOS/Windows state restoration; not visible-placement acceptance |
| Short pressure suites | Passed; actual macOS/Windows exhaustion still unverified |

## Failure corrections

Alloy capture stayed at 1000×700 after requesting 800×600. The host adapter now
requests at most six paints, ≥80 ms apart, stopping at convergence/bound.
Keeping CSS metrics explicit at scale 1 prevents temporary 343×240/206×144 reflow.
This changed public CEF adapter calls, not the CEF framework.

## Remaining evidence

- Linux eight-hour cgroup-growth failure and pending instrumented rerun.
- Later longer macOS stress failed throughput/startup; short passes do not supersede it.
- Actual encoder exhaustion, multi-hour native GPU accounting, and device loss.
- Mixed backing scale and cross-adapter behavior. Two real displays at 2× do not cover these.
- Physical keyboard, native menus, clipboard, IME, machine sleep, and desktop compositors.
- Native browser IME, remote file-transfer UI, and remote audio need implemented paths.

The tables below retain the original baseline/backlog classifications.
Read them as dated run scope, not certification of unrelated working-tree changes.
Record server/host/CEF/frontend/test hashes for each new result.
Disruptive desktop/GPU/sleep tests require a separate recoverable environment.

## Recorded measurements

### Fresh baseline audit

| Platform | Test | Result and scope |
| --- | --- | --- |
| macOS | `tests/chromium/chromium_video_e2e.py`, Chrome | Passed IOSurface capture, hardware HEVC negotiation, independent codecs/renditions, fallback, keyframe recovery, resizing, unsubscribe/resubscribe, and render scale/input coordinates |
| macOS | Same suite, Alloy | Initial binaries failed twice around resize. Current rebuilt artifacts reproduced the failure; see the host-adapter fixes below |
| Windows | `tests/chromium/chromium_native_backend_e2e.py`, both backends | Passed real D3D pixels/opacity, shared storage, tabs, ordering, popups, native presentation, Inspect, resize/backpressure and original-owner replacement |
| Linux | Eight-hour four-configuration soak | Completed 960 samples, then failed X11 Alloy browser-cgroup growth (486.3 MiB versus 256 MiB); all fixture cleanups reported no leaked cgroups; final GPU-reclamation assertion not reached |

### Shared next tests

| Priority | Test and acceptance criteria | Porting requirement |
| --- | --- | --- |
| Done | macOS Alloy resize correction (implemented above); actual Android workflows passed | Rebuilt host adapter; preserved frame/state diagnostics |
| Done | All eight Android scenarios against macOS and Windows, each with Chrome and Alloy | 32/32 final cases; reusable isolated runner and interactive Windows fixtures |
| Done | macOS Alloy GPU-child crash recovery: ten cycles per backend, retained document/browser and fresh decoded video | [Canonical CEF surface-ID fix and rebuilt artifacts](macos-alloy-gpu-recovery.md); native GPU, video, popup/tab and Godot/minimize regressions passed. Native resize/detach passed 3/3 with fixture-only AeroSpace isolation; two-display GPU presentation passed 4/4 per backend with monitor-aware moves. Both displays were 2×, so mixed backing-scale/cross-adapter coverage remains incomplete |
| Partial | Fresh connection, slow/stalled viewer, mixed codecs, churn, bounded viewer pressure and short resource soak passed on all three OSes with both backends; Linux also separates Wayland/X11 | See [stress results](chromium-platform-stress.md); actual macOS/Windows encoder exhaustion and native GPU accounting remain unverified |
| Partial | Native macOS and Windows single- and two-window save/crash/restore passed with Chrome and Alloy | [Checkpoint suite](chromium-platform-checkpoint.md); verifies page order/selection, fresh document state, replacement identity and child cleanup. [Malformed checkpoint rejection passed on both OSes](chromium-platform-profiles.md). Persistent-profile checkpoint restoration and larger graph layouts remain separate cases |
| Partial | Expanded Android clipboard cases passed against macOS/Windows, Chrome/Alloy: textarea/contenteditable, read-only/empty selection, multiline Unicode, payload limits, rapid paste and focus switching | [Clipboard results](desktop-chromium-e2e.md); native Cmd/Ctrl routing, disconnect mid-operation, queue overflow and expanded Linux-host cases remain |
| P1 | Native GPU resource lifetime: retain frames across resize, tab close, disconnect and renderer teardown; reject wrong peer identity and return resources to baseline | IOSurface/Metal on macOS; NT handles/D3D12 on Windows; keep real adapter capability checks |
| P2 | Abrupt browser, renderer, GPU and server exit; recover or present a useful restartable error without stale images or leaked descendants | Windows job objects and native process identities; macOS process identities; do not kill shared desktop/GPU services |
| P2 | Bounded soak followed by multi-hour endurance: decode final frames, compare memory/handles, verify cleanup | Native memory/handle and encoder metrics; actual VideoToolbox capacity rather than assuming an NVENC slot count |
| Partial | Local-capability rejection and workspace/temporary-profile isolation passed on all three OSes with both backends; Linux also separates Wayland/X11 | [Isolation results](chromium-platform-isolation.md); [Persistent-profile close/reopen and storage isolation now passed on macOS/Windows with both backends](chromium-platform-profiles.md); [Cross-server locking and committed-profile recovery after server termination also passed](chromium-platform-profiles.md); remote OPAQUE rejection remains separate |
| P2 | Client network handover and prolonged disconnect | Actual client reconnect/re-authentication and page recovery; TCP-reset protocol tests alone do not cover UI handover |

### OS-specific follow-up

| macOS | Windows | Linux |
| --- | --- | --- |
| Metal/IOSurface import and lifetime | D3D12 debug validation and shared-handle lifetime | Native Wayland and X11 capture/import |
| Cmd clipboard and native menu/focus routing | Ctrl clipboard, Alt/Win key routing and caption/system close | Native clipboard/input method integration |
| Mixed backing-scale movement (same-scale two-display moves passed) | Per-monitor DPI changes and Intel/NVIDIA adapter selection | Fractional scaling, mixed-DPI monitors, GNOME/KDE |
| Occlusion, minimization, Spaces and fullscreen | Minimize/restore, desktop lock and RDP connect/disconnect | Compositor loss/restart beyond private Weston |
| VideoToolbox pressure and recovery | NVENC pressure, device removal and adapter mismatch errors | Different GPU vendors and encoder drivers |
| Real suspend/wake on a controlled machine | Real suspend/resume with a reliable wake/access path | Real suspend/resume with a reliable wake/access path |

## Evidence files

- `.cache/chromium-platform-audit`
- `.cache/mac-alloy-resize`
- `.cache/mac-alloy-resize/verified.json`
