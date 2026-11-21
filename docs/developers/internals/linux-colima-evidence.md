# Colima Linux test record

Recorded evidence; these results apply to the named runs and artifacts.

## Final catalog result

| Outcome | Count |
| --- | ---: |
| Passed | 39 |
| Failed | 22 |
| Timed out | 8 |
| Blocked | 40 |
| Android simulations skipped | 31 |
| Platform-specific not applicable | 56 |

All 196 entries were classified. Native ARM64 Linux/Godot 4.7.2 with Mesa llvmpipe
is functional software-rendering coverage, not physical GPU/performance certification.

## Window and input findings

X11 Xvfb/Openbox and headless Weston passed native-frame checks at 1×/1.5×/2×,
maximize/restore/fullscreen/close routing. Weston lacked optional decoration,
icon, activation, and FIFO protocols; those remain unvalidated.
Linux defaults blur off and places the in-window menu below the title/tab bar.
A five-pixel resize region overlapped the workspace scrollbar; reserving native
border space fixed the replay while maximizing reclaims it.

## Unresolved cases

Transferred-pane input, creation/placement, scrolling/zoom, and animation still
failed. Heavy scenery/effects timed out. Providers, CEF, audio, manual procedures,
and delegated statistics were blocked/unverified. The combined session-switch
case remained failed because its Android presentation portion failed.

## Environment lifecycle

Use a disposable sandbox with private config/state and explicit credential injection.
The test viewer used authenticated view-only VNC; authentication was checked with
real RFB challenge/response. Archive and verify private evidence before removing
disposable VMs. Sparse Colima disks still occupy the host volume; moving build
outputs does not relocate them. Reusable and disposable environments have distinct lifecycles.

No physical trackpad, macOS/Windows application, or physical-GPU sharing acceptance
is inferred from Linux synthetic input or llvmpipe.

## Evidence files

- `artifacts/linux-colima-20261022/`
- `artifacts/linux-colima-20261022/native-arm64/matrix-report.md`
