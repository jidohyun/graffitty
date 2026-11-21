# macOS GPU-child recovery verification

Recorded evidence; these results apply to the named runs and artifacts.

## Validation — 2026-11-02

The stale embedded child-surface ID was fixed in the canonical CEF patch and
verified against staged and rebuilt release hosts. **Ten recovery cycles per
backend** retained browser/document identity, observed replacement GPU PIDs,
and decoded 60 changing frames. All fixtures cleaned up.

Three staged runs plus a release run covered eight cycles/backend; two-display
follow-up added two. Staged recovery+decode took 2.74–2.96 s/cycle.
Native IPC GPU, video, popup/tab, Godot capture/minimize, and Chrome power-assertion
regressions also passed against the rebuilt release.

## Failure and correction

Original Alloy capture stalled after one or two frames despite a live document,
replacement GPU, and enabled/error-free capturer. Resize and real empty-subscription
visibility cycling did not repair it. Diagnostic run4 used an unsupported unsubscribe
message and cannot prove hide/show. Run5 telemetry failure is not a product verdict.
Chrome/macOS and both Windows backends passed their original corresponding cases.

The resumed test requires consecutive replacements, advancing animation, retained
identity, and decoded fresh video. Patching surface embedding fixed the Alloy path;
the framework/archive/provenance/DVC metadata and native host were rebuilt.
No installed application was replaced by these tests.

## Window-manager-aware follow-up

Native resize/detach passed 3/3 after isolating newly detached fixture windows as
well as the original from AeroSpace tiling. Two-display Godot placement/GPU movement
passed 4/4 Chrome and 4/4 Alloy with monitor-aware fixture moves.
Original nonisolated/non-monitor-aware failures remain failures.

## Reproduce

Use a new artifact directory. The helper verifies the owned parent/executable
before killing its GPU child; it does not reset the system GPU.

## Remaining limits

Both displays had 2× backing scale despite different physical DPI. This does not
cover a backing-scale change, cross-GPU motion, earlier three-display topology,
physical GPU reset, device removal, or machine sleep/wake.

## Commands and examples

### Reproduce

```sh
uv run tests/chromium/test_chromium_platform_gpu_recovery.py \
  --platform macos --backend alloy \
  --server "$PWD/target/release/gft" \
  --host "$PWD/dist/$(cat dist/chromium-host-path.txt)" \
  --shell /bin/sh \
  --artifacts .cache/chromium-acceptance/mac-alloy-gpu-resume
```

## Evidence files

- `.cache/chromium-acceptance`
