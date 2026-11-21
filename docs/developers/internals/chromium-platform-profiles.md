# Browser profile and recovery verification

Recorded evidence; these results apply to the named runs and artifacts.

## Verification results

| Matrix, macOS/Windows × Chrome/Alloy | Result |
| --- | --- |
| Profile reopen | Four cases, twelve browser cycles passed |
| Damaged checkpoints | Sixteen rejects/OS, 32 total; valid prepare before/after |
| Cross-server crash recovery | Four cases/twelve server fixtures passed |
| Expanded IndexedDB/video run | Committed structured records retained; aborted writes rolled back; HEVC frame delivered |

All owned descendants were gone. Windows normal contender/replacement teardown
was forced; crash injection killed only the original server and independently
required browser exit. Linux had not run these suites at that record point;
[later acceptance results](chromium-acceptance-checklist-evidence.md) are separate.

## Persistent-profile assertions

Reject a second host while the original remains usable. Other persistent/temporary
profiles inherit no cookie/localStorage/IndexedDB data.
Across three close/reopen cycles, process identities change; committed storage
persists, sessionStorage/unsaved JavaScript does not. Profiles are disposable fixture
files, not personal browser profiles.

## Checkpoint validation

`tests/server/test_checkpoint_validation_native.py --cli ... --seed ... --artifacts ...`
uses a real OS-native checkpoint. Save/input and prepare-only restore must reject:
truncation, wrong version, no windows, bad geometry, duplicate pane, missing browser
owner, disallowed URL scheme, and empty pages. Diagnostics must match and leave
valid input/recovery files unchanged. Valid recovery must still work afterward.

## Cross-server locking and crash recovery

`tests/chromium/test_chromium_platform_profile_recovery.py` starts owner, contender, then
replacement. Commit a cookie/localStorage/Unicode IndexedDB record before crash.
An aborted overwrite must not replace it before or after recovery. Retain committed
storage on replacement but clear transient state. Require an encoded positive-size
H.264/HEVC frame; this alone does not decode pixels or assess quality.

The original Mac fixture published cleanup before closing its origin socket,
causing address-in-use. Releasing the socket first corrected the fixture; retain
the failed run separately from product verdicts.

## Coverage limits

CDP assertions do not test native keyboard/clipboard or frontend checkpoint restoration.
Writes racing a crash, encrypted login-cookie portability, disk-full behavior,
concurrent pruning, and malicious filesystem races need separate tests.

## Evidence files

- `.cache/chromium-platform-profiles`
- `.cache/chromium-platform-profile-recovery`
