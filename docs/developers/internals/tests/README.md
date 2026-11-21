# Test dashboard

Open [the video wall](index.html) to inspect recorded replays.
Specifications live in `tests/llm-e2e/suites/`. A recorded pass covers that case's assertions, not full product acceptance.

## Find a suite

| Suite | Cases | Recorded passes | Other recorded outcomes |
| --- | ---: | ---: | ---: |
| [agent-graph](index.html#agent-graph) | 9 | 0 | 0 |
| [android-runtime](index.html#android-runtime) | 67 | 32 | 1 |
| [android-simulated](index.html#android-simulated) | 33 | 23 | 0 |
| [bistro-world](index.html#bistro-world) | 7 | 4 | 0 |
| [chromium](index.html#chromium) | 1 | 0 | 0 |
| [configuration](index.html#configuration) | 1 | 0 | 0 |
| [filetree](index.html#filetree) | 1 | 0 | 0 |
| [flat-world](index.html#flat-world) | 13 | 5 | 0 |
| [integration](index.html#integration) | 16 | 0 | 0 |
| [mac-trackpad](index.html#mac-trackpad) | 8 | 0 | 0 |
| [media-transport](index.html#media-transport) | 3 | 0 | 0 |
| [remote-control](index.html#remote-control) | 2 | 0 | 0 |
| [sessions](index.html#sessions) | 4 | 0 | 0 |
| [tabs-and-panes](index.html#tabs-and-panes) | 39 | 25 | 0 |
| [terminal-appearance](index.html#terminal-appearance) | 2 | 0 | 0 |
| [terminal-effects](index.html#terminal-effects) | 1 | 0 | 0 |
| [terminal-protocol](index.html#terminal-protocol) | 2 | 0 | 0 |
| [terminal-tools](index.html#terminal-tools) | 1 | 0 | 0 |
| [text-quality](index.html#text-quality) | 2 | 1 | 0 |
| [windows](index.html#windows) | 7 | 0 | 0 |

Unrecorded cases are not passes. See each suite for failures, blocked cases, and missing recordings.

## Update recordings

1. Record Mac replays: `uv run tests/godot/test_dashboard.py record`.
2. Import APK evidence: `uv run tests/godot/test_dashboard.py import-android EVIDENCE_DIRECTORY`.
3. Rebuild this index: `uv run tests/godot/test_dashboard.py build`.

## Fast rules (722 passed, 0 failed in 10.6 s)

Build the isolated Rust graph fixture with `cargo build -p graffitty-workspace-core --example graph_fixture`, then run `godot --headless --path frontends/godot/project --script tests/run.gd`. No application sessions or model calls are used.

The video wall retains every case, assertion, replay, recording, and full fast-rule result. This page lists only fast-rule failures below.


The video wall contains the full fast-rule results.
