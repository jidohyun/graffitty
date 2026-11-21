# Browser isolation verification

Recorded evidence; these results apply to the named runs and artifacts.

## Recorded status

Nov 1: macOS/Windows × Chrome/Alloy passed all four cases with zero surviving
owned descendants. Windows teardown was explicitly forced. Binaries were existing
verified artifacts, not a claim that unrelated source edits were rebuilt.
At this record's earlier point, Linux cases were queued; later results are indexed
in [the acceptance ledger](chromium-acceptance-checklist-evidence.md).

## Assertions

| Boundary | Check |
| --- | --- |
| Temporary profiles | No cookie/localStorage leakage within or across workspaces |
| Topology/subscriptions | No foreign browser, including explicit numeric-ID subscribe |
| RPC routing | Reject foreign navigate/input/close/result-fetch; legitimate owner still gets its result |
| Authentication | Wrong token/version or unauthenticated request receives no app data |
| Reconnect | Retains own document/storage/hardware stream without affecting other workspace |

## Run

Use `tests/chromium/test_chromium_platform_isolation.py` with the platform/binary/SSH/artifact
arguments of the shared stress runner. A private loopback HTTP origin gives profiles
the same origin without external websites.

## Limits

These are local-capability/routing checks. A server-capability holder may deliberately
connect to another workspace; workspaces are not security principals against the
server administrator. No OPAQUE remote-login, persistent-profile, or native-UI
restoration acceptance follows from these cases.

## Evidence files

- `.cache/chromium-platform-isolation`
