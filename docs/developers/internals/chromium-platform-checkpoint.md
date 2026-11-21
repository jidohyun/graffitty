# Native browser checkpoint verification

Recorded evidence; these results apply to the named runs and artifacts.

## Verification record

| Run | Result |
| --- | --- |
| macOS/Windows × Chrome/Alloy, single window | Four cases/eight frontend capture/restore phases passed |
| Same matrix with two windows | Four cases passed; two terminals/two browsers/four pages each |
| macOS default single-window Chrome regression | Passed after shared-script change |

All recorded frontend phases removed private user directories and had no frontend
ERROR logs. Server-crash children exited without fixture intervention; normal
Windows replacement teardown is an explicitly forced process-tree stop.

## What recovery proves

1. Create two pages, select the second, and set unsaved document state.
2. Capture through the native frontend; save through native CLI while shell PIDs live.
3. Check canonical selected-page-first URLs, owner identities, and topology.
4. Kill only the owned server and independently require child exit.
5. Replace it, restore, and verify new process/document identity and preserved layout.

Two-window phases also check mapped pane/tab/graph data and per-window URLs.
Unsaved JavaScript must be absent in fresh documents.

## Prepare the fixture

Use a private imported project with current scripts/assets and a matching extension.
Windows requires the supported build script's static-runtime configuration and
an interactive browser task; frontend phases are headless.
Existing override.cfg is rejected. Every phase gets isolated Godot/XDG/checkpoint data.

## Retained setup failures

Too-old Rust, wrong CMake generator, and direct-Cargo runtime mismatch were fixture
setup corrections, not a reproduced browser defect. Keep their logs/hashes.

## Coverage limits

Native Linux needs its own Godot/extension runtime. A macOS frontend saving a Linux
owner does not establish native Linux frontend coverage.
Headless windows prove state restoration, not visible placement, physical shortcuts,
monitor DPI, focus, or GPU presentation.

## Commands and examples

### Native Chromium checkpoint recovery

```sh
uv run tests/chromium/test_chromium_platform_checkpoint.py \
  --platform macos --server /path/to/gft --host /path/to/host.app/Contents/MacOS/probe \
  --shell /bin/sh --godot /path/to/godot --project /path/to/private/project \
  --artifacts .cache/checkpoint/macos

uv run tests/chromium/test_chromium_platform_checkpoint.py \
  --platform windows --ssh windows-test-host \
  --server C:/test/gft.exe --host C:/test/cef/graffitty_chromium.exe \
  --shell 'C:/Program Files/Git/bin/bash.exe' --godot C:/test/godot_console.exe \
  --project C:/test/project --python C:/test/python.exe \
  --remote-dir C:/test/fixtures --principal-task ExistingInteractiveTestTask \
  --artifacts .cache/checkpoint/windows
```

## Evidence files

- `.cache/chromium-platform-checkpoint/macos-native`
- `.cache/chromium-platform-checkpoint/windows-1`
- `.cache/chromium-platform-checkpoint/macos-multiwindow`
