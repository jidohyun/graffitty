# Chromium acceptance ledger

Recorded evidence; these results apply to the named runs and artifacts.

## Latest recorded verdicts

| Area | Result |
| --- | --- |
| Native frontend input | Eight final cases ×47 assertions passed; 22 event units passed |
| Graph smoke | 76 assertions passed, but existing shutdown warnings remain |
| Longer macOS stress | Chrome throughput failed; Alloy startup failed |
| Linux original eight-hour | Failed total-cgroup growth |
| Linux instrumented eight-hour | Pending |
| macOS GPU-child recovery | Ten cycles/backend, fresh decoded frames and clean child teardown |
| macOS two-display GPU | 4/4 per backend; native resize/detach 3/3 with fixture isolation |
| Rebuilt Linux profile/isolation/recovery | 16 final Wayland/X11 × backend cases passed |

## Additional completed checks

- Native macOS IPC GPU: five cases/backend after decoder-ABI/build updates.
- Godot native GPU presentation: macOS/Windows both backends; fresh socket-bound proofs.
- Windows hardware video: seven required-hardware tests; H.264/HEVC available, no AV1.
- macOS checkpoint CLI: ten passed; server five initially, node-state separately after pydantic setup.
- Persistent two-window checkpoints passed macOS both backends.
- Windows checkpoint lock test: 24 writers, seven history reads, four restore prepares;
  four valid documents retained; 16 malformed rejects and valid recovery passed.
- Windows template independent-copy checks passed both backends.
- Window lifecycle/minimize/restore passed both backends on macOS/Windows.
  Windows uses a host-owned 250 ms mode timer for otherwise-missed unfocused minimization.

## Preserve scope and failures

Input is synthetic in-process frontend input, not physical IME/native menu acceptance.
Mac graph negative controls showed key delivery alone does not execute browser undo.
Original prefix-expectation, transitional-video, native-window, and display-fixture
failures remain recorded; isolated passes do not retroactively pass them.

Earlier single-display results do not establish mixed DPI, backing-scale transitions,
or cross-adapter behavior. The initially selected obsolete Linux host is excluded
from final current-host evidence. Tests require exact artifact hashes and cleanup.

The requirement matrix below is an acceptance inventory, not an all-pass statement.

## Recorded measurements

### Chromium acceptance checklist

| Area | Required cases | Current evidence / next action |
| --- | --- | --- |
| Native host | Launch/close, actual pixels/opacity, page ordering, popup lifecycle, native presentation, resize/backpressure | Existing macOS/Windows native reports; Linux backend reports |
| Video | H.264/HEVC negotiation, fallback, static updates, keyframes, dimensions, scale/colour fidelity, unsubscribe/reconnect | Existing video and Android matrices |
| GPU resource lifetime | Retain imports across resize/disconnect/host close, peer-identity rejection, failed-import fallback, destination release, fresh proof after reconnect | macOS five-case transport suite passed both backends; Windows seven native tests include kernel peer/device proof, wrong-server rejection, texture scaling and static updates |
| GPU frontend | Native texture presentation, resize, reconnect, codec fallback and pixel evidence | macOS/Windows actual Godot GPU suites passed both backends; Linux uses negotiated video, not Chromium shared GPU transport |
| Linux native frontend | Actual Wayland/X11 Godot pixels, negotiated video, resize, reconnect and hide/show | All four backend/display video cases passed with current-source CLI/extension and rebuilt host, including exit; one earlier Wayland Alloy shutdown hang on the old server remains an unresolved intermittent failure |
| Shared viewers | Mixed codecs, stalled/resumed viewer, churn, six-viewer pressure, bounded resource growth | macOS/Windows passed; current-source Linux passed both backends on Wayland/X11, including explicit pressure rejection and recovery |
| Endurance | Four Linux backend/display configurations, final decode, process/GPU resource samples | Original eight-hour run failed X11 Alloy cgroup growth. Instrumented rerun remains active; at ~6h X11 Chrome's charge exceeds the growth limit, primarily file cache alongside a late model download. Final acceptance pending |
| Authentication | Wrong/missing capability/version, unauthenticated commands, workspace routing/result ownership | macOS/Windows passed; Linux passed both backends on Wayland/X11 |
| Remote authentication | OPAQUE rejection/re-authentication and reconnect | macOS password rejection/restart and encrypted outage recovery passed; Windows passed |
| Profiles | Temporary isolation, explicit persistent isolation, close/reopen, cookies/localStorage/IndexedDB, lock rejection | macOS/Windows passed; Linux persistent/temporary isolation, close/reopen and lock rejection passed both backends on Wayland/X11 |
| Profile crash recovery | Cross-server lock, committed storage, aborted transactions, fresh document, replacement video | macOS/Windows passed; Linux passed both backends on Wayland/X11 |
| Profile templates | Locked-template rejection, copied storage, copy isolation, template unchanged | macOS/Windows passed; Linux passed both backends on Wayland/X11 |
| Checkpoints | One/two windows, ownership, selected-page ordering, fresh document, native CLI save/restore | macOS/Windows passed |
| Persistent checkpoints | Explicit profiles restored by native frontend after server replacement | macOS/Windows both backends passed; Windows Alloy startup flake retained for follow-up |
| Large checkpoints | Multiple terminal tabs, splits, graph edges and node state, mixed browser/terminal windows | macOS/Windows complex native restore passed; Linux remains separate |
| Invalid checkpoints | Truncated/version/geometry/IDs/owner/URL rejection; preserve valid recovery | Native CLI passed on macOS/Windows/Linux; Linux current-source release rejected all 16 malformed inputs and preserved valid recovery |
| Concurrent checkpoints | Concurrent saves, retention/pruning, atomic readable documents and restores | macOS/Windows/Linux passed with the new per-history lock, including concurrent restore preparation |
| Faults | Browser/renderer/server exit, stale-frame removal, useful restart, owned child cleanup | GPU-child recovery passed both macOS backends after the Alloy surface-ID fix (ten cycles each), plus earlier Windows passes; physical GPU reset remains untested |
| Clipboard | Unicode/multiline/contenteditable/read-only/empty/limits/rapid/focus; ownership, stale replies, disconnect, queue bounds | Expanded Android macOS/Windows passed; exclusive ownership/foreign reply/reset/transfer suites passed on both |
| Navigation/input | URL entry, history, popup/tab switching, touch/scroll/scale, keyboard and native shortcuts | Android matrix passed; synthetic in-process desktop input passed macOS/Windows Chrome/Alloy 2/2 each after undo routing/command correction; physical keyboard/menu/IME remain separate |
| Network | Slow/stalled link, reconnect, prolonged disconnect, actual client network handover | Protocol stress passed; physical-client handover pending |
| Native window lifecycle | Close one owner, remaining window survives, minimize/restore/occlusion, focus | Actual macOS/Windows minimize/restore passed both backends after fixing missed Windows mode notifications; occlusion/focus remain separate |
| Displays | Retina/per-monitor DPI, display movement, multiple GPU adapters | macOS two-display, window-manager-aware movement passed 4/4 per backend with fresh pixels and placement checked through capture; both displays were 2×. Earlier three-display, mixed-backing-scale and cross-adapter coverage remain unaccepted |
| Suspend and device recovery | Real suspend/wake, GPU device removal, compositor restart | Requires recoverable machine/access path; do not treat process restart as equivalent |
| Unsupported workflows | Native browser IME, remote file transfer and audio | Product capability/implementation audit; cannot claim user-workflow passes from CDP substitutes |
| Cleanup | Every owned fixture: child exits, task removal, private userdata cleanup, failure evidence retained | Required for every executed case |

## Evidence files

- `.cache/chromium-acceptance`
- `.cache/chromium-acceptance/linux-godot-video-pure-*`
- `.cache/chromium-acceptance/linux-portable-final-*`
- `.cache/chromium-acceptance/linux-endurance-8h`
