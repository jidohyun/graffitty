# Replay review ledger

Recorded evidence; these results apply to the named runs and artifacts.

## Latest recorded result — 2026-10-04

See [Feature audit](FEATURE-AUDIT.md) for final 67 desktop replays (25 Android
simulations),33 APK cases,30 GPU smokes,133 Godot units,96 Rust, and78 Python
passes with 9 Windows skips. These counts are historical run results.

## Review history

| Period | Recorded outcome | Scope/caveat |
| --- | --- | --- |
| Sep28 original catalog | 25/25 replays;55 units; all 25 AV1 clips completed | Rendered scripted input, not external LLM service |
| Resource-strip follow-up | Overview/stash/UI/text checks passed;57 units | Header geometry, live values, nonoverlap, alpha sampling |
| Oct3 Android initial expansion | Ten APK cases passed;133 units | API36 ARM64 emulator; most gestures were in-process events |
| Oct3–4 hands-on reviews | Failed | Broad manual procedures remained incomplete |
| Touch/IME focused correction | 32/32 automated APK,24 simulated replays, four native regressions passed | Native Gboard/Android taps only in their named cases |
| Final focused APK | Chromium/messages/tiling/prefix reruns passed | Not broad OEM/emoji/portrait acceptance |
| Oct4 broad feature audit | Final recorded counts above | Original failures retained beside reruns |

## Corrections checked

Bistro lighting/routes/resize retargeting, physics-settle assertions, isolated
replay input/DPI, sharpened text negative controls, and240s recording duration
corrected the desktop fixtures.
Android corrections covered Mobile blur fallback, scrollable connection controls,
held-contact cancellation, clipboard focus, pane/graph touch routing, keyboard
layout, per-tab placement, and updated script staging.

## Read evidence correctly

Continuous recordings/contact sheets establish sampled visible behavior; sparse
sheets do not prove every frame. Bistro preview seams/denoising remained and full
production-resolution baking was not run.
Native Gboard composition is distinct from Unicode injection. Broader manual IME
still needed portrait/emoji/connection fields/OEMs. No physical-phone stress,
other-OS application acceptance, VPN disruption, or real chat delivery follows
from automated APK/simulated passes.

The final audit independently records real provider, SSH, PTY, browser, password,
and Mac trackpad checks. Keep those results separate from simulated fixtures.
This ledger preserves earlier failures; later focused passes do not rewrite them.

## Evidence files

- `.cache/e2e-full/review/`
- `.cache/e2e-full/text-quality/`
- `.cache/bistro-baked/preview/`
- `.cache/bistro-e2e/current/flights.json`
- `.cache/e2e-full/tests-complete.log`
- `.cache/e2e-full/recordings-final.log`
- `build/android/e2e/20261003-204031/results.json`
- `build/android/e2e/workspace-simulated-confirmed.log`
- `build/android/e2e/workspace-apk-final/`
- `build/android/e2e/portrait-apk-final/`
- `build/android/exploratory/REPORT.md`
- `build/android/e2e/fixes-apk-all/results.json`
- `build/android/e2e/usability-apk-final/results.json`
- `build/android/fix-review-final/`
- `build/android/fixes-sim-final.log`
- `build/android/hands-on/REPORT.md`
- `build/android/hands-on/ime-fresh-launch-pass.mp4`
- `build/android/fix-touch/`
- `build/android/fix-touch/final-focused-apk/`
- `build/android/fix-touch/REPORT.md`
- `build/feature-audit/verified-results.json`
