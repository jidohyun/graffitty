# Real Codex and Claude graph

Exchange real model responses in both directions and route exactly one Codex turn completion notification into Claude.

Run from the repository root:

```sh
python3 tests/agents/test_agent_e2e.py --case cross
```

Use installed Codex and Claude with real provider authentication. Use GPT-6 Luna with low effort and pinned Haiku 4.5; never substitute a larger model. Keep test homes and sessions isolated. Never use an existing user pane, start a second writer on a user thread, or modify personal config. The replay owns all panes it types into.

## Launch and identify

Start the installed CLI inside a newly created real Graffitty pane in an empty test directory. Require a fresh session ID, an assistant-only READY response and idle state. Read the recorded model identity; a different model fails. Codex daemon discovery must use its PID-owned listener, with no launch context or title configuration.

## Bidirectional delivery

Connect Send edges and send a unique reply marker through the graph. Native acceptance alone is insufficient: require an assistant transcript response and idle. Place an unsent draft in the recipient and verify it survives. Cross-provider runs exercise Codex → Claude and Claude → Codex. Never infer model completion from prompt text or terminal rendering.

## Completion notification and read

Enable only Codex → Claude Turn completed to avoid a completion loop. Ask Codex to output a short instruction containing a unique marker. Wait for Claude to answer that marker once. Use graph.read from Claude and require a file reference, without an unsolicited history dump. Do not synthesize a Stop hook.

## Evidence and result

Retain report.json, replay.log and evidence.json in the private run directory. Report PASS, FAIL or BLOCKED. Authentication, model access, unavailable sockets or denied process inspection are BLOCKED, never PASS. A receipt without an assistant response does not prove delivery completion. Live visual quality requires a separate windowed recording.
