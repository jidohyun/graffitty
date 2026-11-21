# Desktop-host Android browser matrix

Recorded evidence; these results apply to the named runs and artifacts.

## Verified results — 2026-11-01

All **32 final cases** passed on a physical tablet against macOS/Windows servers,
with Chrome and Alloy. macOS used the rebuilt adapter; Windows used its previously
verified native host. This is not a fresh Windows CEF or native desktop frontend pass.

All 32 fixtures left no descendants. Sixteen macOS servers exited normally;
Windows process trees were intentionally terminated (exit1 is not graceful shutdown).
Temporary tasks/disposable APK uploads were removed.

## Retained failures and corrections

| Earlier result | Correction / limit |
| --- | --- |
| macOS debug server 12/16 | Color/scroll bugs fixed; URL-under-load misses did not recur on release but have no claimed root-cause fix |
| Chrome HEVC colors wrong | GPU conversion to explicit video-range NV12/BT.601; ten native video tests passed |
| Alloy reduced-raster short scroll | Scale hit coordinates, not CSS wheel distance; actual 210 px scroll verified |

DOM wheel deltas are diagnostics, not a substitute for actual visible movement.
The encoder conversion uses GPU completion/retained buffers, without CPU readback.

## Expanded clipboard verification

Four later runs ×76 checks passed: Unicode/multiline, empty selections,
contenteditable cut/paste, focus, read-only/password protection, six rapid pastes,
and oversized rejection. Routine state updates now preserve clipboard failure
messages until the next clipboard shortcut. Original failures remain retained.

## Running the matrix

Use a direct authenticated tablet connection—no ADB forwarding or authentication
bypass. Windows needs psutil and an existing interactive principal; both hosts need
a POSIX shell with seq for flood tests. Fresh fixture tasks are removed afterward.
`--case` / `--backend` narrow reruns. The eight scenarios/backend are hardware,
navigation, touch, scroll, background/resume, crash, URL-under-load, and clipboard.

Evidence records binary/script/APK hashes, screenshots, logs, assertions, and cleanup.
Physical tablet workflows do not establish desktop native-menu/IME coverage.

## Recorded measurements

### Verified results — 2026-11-01

| Scenario | macOS Chrome | macOS Alloy | Windows Chrome | Windows Alloy |
| --- | --- | --- | --- | --- |
| Hardware backend and popup pixels | Pass | Pass | Pass | Pass |
| Navigation | Pass | Pass | Pass | Pass |
| Touch and scaled input | Pass | Pass | Pass | Pass |
| Scroll stability | Pass | Pass | Pass | Pass |
| Background/resume | Pass | Pass | Pass | Pass |
| Browser/renderer/stuck-page recovery | Pass | Pass | Pass | Pass |
| URL updates under terminal load | Pass | Pass | Pass | Pass |
| Clipboard | Pass | Pass | Pass | Pass |

## Commands and examples

### Commands

```sh
uv run tests/chromium/test_desktop_chromium.py \
  --platform macos --server /path/to/gft --host /path/to/host.app/Contents/MacOS/probe \
  --shell /bin/sh --listen desktop-address:41819 --adb tablet-serial \
  --artifacts .cache/desktop-chromium/macos

uv run tests/chromium/test_desktop_chromium.py \
  --platform windows --ssh windows-test-host \
  --server C:/test/gft.exe --host C:/test/cef/graffitty_chromium.exe \
  --shell 'C:/Program Files/Git/bin/bash.exe' --listen desktop-address:41819 \
  --python C:/test/python.exe --remote-dir C:/test/fixtures \
  --principal-task ExistingInteractiveTestTask --adb tablet-serial \
  --artifacts .cache/desktop-chromium/windows
```

## Evidence files

- `.cache/chromium-platform-audit`
- `.cache/mac-alloy-resize/desktop-final`
- `.cache/chromium-platform-audit/mac-video-units-final.log`
- `.cache/chromium-platform-clipboard`
