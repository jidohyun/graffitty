# Native browser input verification

Recorded evidence; these results apply to the named runs and artifacts.

## Verification — 2026-11-02

| Check | Result |
| --- | --- |
| macOS/Windows × Chrome/Alloy, two final runs each | Eight cases ×47 assertions passed |
| Chromium event units | 22 passed |
| Graph smoke | 76 assertions passed, but 113 ObjectDB/five-resource shutdown warnings remained |
| Unchanged graph baseline | 72 assertions with same warnings; no clean whole-test verdict |
| macOS native GPU/fallback regressions | Both backends passed |

Windows teardown is explicitly forced; macOS requires normal exit.
All owned processes/private directories and temporary Windows tasks were cleaned up.

## Input path and assertions

Synthetic pointer/keyboard events enter real Godot routing. CDP only sets up and
observes DOM. Check imported pixels, focus, Unicode/editing/Tab, read-only fields,
resize click mapping, wheel scrolling, document/owner retention, and fresh
connection-bound GPU proof after reconnect.
Single Cmd/Ctrl+A arms the workspace prefix; repeating forwards Select All.
Established GPU intervals require zero additional CPU decoding. Transitional
video during reconnect is counted separately.

## Undo correction

Graph input intercepted Cmd+Z because it checked window text fields but not
browser/canvas focus in the separate viewport. Yield to workspace text focus.
A negative control then delivered the DOM key without changing text: explicit
Blink undo/redo commands were also required. Strip those commands from synthesized
focus-loss releases to avoid repeating the edit on key-up.
No CEF or schema change was needed.

## Retained failures and limits

Initial prefix expectations, graph-only GPU-readiness failure, and Windows
transitional-video assertion failures remain evidence, not passes. The completed
Mac command-only negative control isolates the need for explicit edit commands.

Use private imported projects and matching extension/binary hashes. Windows needs
an interactive headful session; macOS uses guarded background Metal.
This does not establish physical keyboards, native menus, OS clipboard, IME,
or unrelated desktop focus/occlusion. Final Mac verification did not overlap
the separately failed longer stress run.

## Commands and examples

### Native frontend Chromium input follow-up

```sh
uv run tests/chromium/test_godot_shared_gpu.py \
  --scenario input --backend chrome \
  --project /path/to/private/project --server /path/to/gft \
  --chromium-host /path/to/host --godot /path/to/godot \
  --evidence .cache/chromium-input/chrome
```

## Evidence files

- `.cache/chromium-acceptance`
