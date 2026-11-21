# Real native Codex without daemon

Verify no-daemon lifecycle and turn completion notifications to Claude, while incoming native queue delivery fails explicitly without terminal injection.

Run from the repository root:

```sh
python3 tests/agents/test_agent_e2e.py --case codex-local
```

Use installed Codex and Claude with real provider authentication. Use GPT-6 Luna with low effort and pinned Haiku 4.5; never substitute a larger model. Keep test homes and sessions isolated. Never use an existing user pane, start a second writer on a user thread, or modify personal config. The replay owns all panes it types into.

## Launch and identify

Start the installed CLI inside a newly created real Graffitty pane in an empty test directory. Require a fresh session ID, an assistant-only READY response and idle state. Read the recorded model identity; a different model fails. Codex daemon discovery must use its PID-owned listener, with no launch context or title configuration.

## Unavailable queue capability

Send to the native --no-daemon Codex session. Require an explicit failed receipt and no injected user message. This tests the current unavailable capability; it must not silently route through another daemon.

## Completion notification and read

Enable only Codex → Claude Turn completed to avoid a completion loop. Ask Codex to output a short instruction containing a unique marker. Wait for Claude to answer that marker once. Use graph.read from Claude and require a file reference, without an unsolicited history dump. Do not synthesize a Stop hook.

## Evidence and result

Retain report.json, replay.log and evidence.json in the private run directory. Report PASS, FAIL or BLOCKED. Authentication, model access, unavailable sockets or denied process inspection are BLOCKED, never PASS. A receipt without an assistant response does not prove delivery completion. Live visual quality requires a separate windowed recording.
