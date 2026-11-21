# Chromium scroll investigation records

Recorded evidence; these results apply to the named runs and artifacts.

## Results and unresolved failures

| Area | Recorded finding |
| --- | --- |
| Mac compositor | Disable TreesInViz as targeted crash-path mitigation; original trigger not proved eliminated |
| Original Android test | Apparent pass hid HEVC→H.264→PNG fallback; stronger tests reject it |
| Native decoder replay | Original stream reproduced surface errors; bounded-reference HEVC/H.264 passed |
| Traced full client rerun | 12 scrolls/zoom changes passed on HEVC, zero native/CDP errors |
| Intermittent scroll stall | Not established fixed; connection observations do not prove cause |
| Stopped-reader Mach transfer | Reproduced rights leak; mach_msg_destroy regression verifies release |

## Encoder/decoder correction

Reference budgeting on macOS 13+ reduced surface pressure. A one-reference variant
was rejected because low-delay hardware round trip stalled. Compression efficiency
may change; unchanged quality at fixed bitrate is not promised.
Android drains output and displays newest completed frames, but keeps compressed
reference packets ordered. TRY_AGAIN_LATER is backpressure: retain the exact pending
packet, poll output, retry after 4 ms. Queue is bounded to 32 plus pending;
sustained overload can still reject a codec.

## Adaptive resolution and input

Height tiers are 144/240/360/540/720/1080/1440/2160p. Grow promptly; shrink after
500 ms with 10% margin. User limits remain caps, per viewer/rendition.
CDP raster scale preserves inner size/layout/DPR. Reduced-raster click mapping
must use CSS coordinates, not physical video pixels.
The degraded traced run presented 7–24 frames/scroll and a 781 ms maximum gap;
this is not 60 FPS or an end-to-end latency claim.

## Lifecycle findings

A 60 Hz macOS fallback VSync timer kept captures advancing with the display asleep:
359 callbacks versus 2 without it. Locking alone was not the trigger.
Temporary-profile deletion previously outlived server exit: 108 orphan profiles/13 GB
motivated bounded lifecycle cleanup.

Stopped browsers now report reason, restartability, and selected-page-first URLs.
Concurrent Restart treats an already relaunching browser as restarted. Detached
window restart/unwritable-profile behavior was not covered.
Stable CDP-target IDs fix tab reorder confirmation. Component updates stay enabled;
disabling them also stops certificate-revocation/Widevine updates.

## Mach-right leak

Timed-out Mach sends return possibly renamed rights and destination references.
Destroy the returned message rather than freeing only the old surface name.
The reproduction leaked 198 names/references for 198 sends; corrected destruction
leaked none. A stopped-reader regression checks actual port counts.
The observed 378 GB charged footprint/67,153 ports was not ordinary process heap.

## Test boundaries

3,840 inputs/32 endpoints/three clients passed before reference budgeting; the
bounded run passed 12 endpoints at 1000×700. Native original stream is an expected
failure control. Mac GPU 26 checks, six hardware codec and seven server tests passed.
Client scrolling used synthetic Godot events, not physical Android gesture recognition.
Deliberate Page.crash/GPU-abort tests caused 43 system crash reports; normal fault
runs now use owned SIGKILL and assert no new report. Keep excluded disk-full and
interrupted runs outside passing evidence.

Native/physical sample evidence and website-detection observations are dated to
this build, not universal media/DRM or browser compatibility claims.

## Recorded measurements

### Follow-up: render scale, slow links and session storage

| Client link | Before | Rendition pauses | Plus 10 s keyframe interval |
| --- | --- | --- | --- |
| 500 KB/s | 11.2 fps, 71 of 112 frames keyframes, 0.21 s gaps | 30.9 fps, 5 keyframes | 30.6 fps, 0 keyframes, 0.08 s gaps |
| 250 KB/s | — | 15.2 fps, 2 keyframes | 15.2 fps, 0 keyframes |

### Follow-up: crash alerts and late-ready panes (2026-10-25)

| Window | Without probe | With probe |
| --- | --- | --- |
| First minute after creation | 59.6%, 67.2% of a core | 65.2%, 67.9% |
| Steady state (after 90 s) | 19.5% | 21.5% |

### Follow-up: crash alerts and late-ready panes (2026-10-25)

| Signal | Before | Cause | Now |
| --- | --- | --- | --- |
| `navigator.webdriver` | `true` | `--remote-debugging-pipe`, kept for optional leased automation, makes Chromium report the whole browser as automated; sign-in pages and bot checks refuse it | `false` (`--disable-blink-features=AutomationControlled`); leased automation still drives the page |
| H.264 / AAC in `MediaSource` | unsupported | the CEF build sets no `proprietary_codecs` | unchanged: needs a CEF rebuild |
| Widevine | `NotSupportedError`, also after two minutes with component updates on | DRM module not available to this build | unchanged |
| `document.hasFocus()` | `false` | the window is hidden and never key | unchanged; `Emulation.setFocusEmulationEnabled` makes it `true` |
| `outerWidth` while a pane is shown small | 342 for an `innerWidth` of 1280 | the adaptive render scale resizes the hidden window | unchanged |

## Evidence files

- `build/chromium-stability/server-final`
- `build/chromium-stability/server-bounded`
- `build/chromium-stability/native-original-hevc`
- `build/chromium-stability/native-ref2-hevc`
- `build/chromium-stability/native-server-bounded-hevc`
- `build/android/e2e/chromium-scroll-tablet-retry`
- `build/android/e2e/chromium-scroll-mac-bounded`
- `build/android/e2e/chromium-scroll-tablet-confirm`
- `build/android/e2e/chromium-adaptive-mac`
- `build/chromium-stability/native-scroll-traced`
- `build/android/e2e/chromium-adaptive-tablet`
- `build/android/e2e/chromium-adaptive-tablet-traced`
