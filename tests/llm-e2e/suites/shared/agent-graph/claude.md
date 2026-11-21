# Real Claude Haiku

Discover real Claude, deliver over its authenticated socket, preserve drafts, and reconnect without changing the session.

Run from the repository root:

```sh
python3 tests/agents/test_agent_e2e.py --case claude
```

Use installed Codex and Claude with real provider authentication. Use GPT-6 Luna with low effort and pinned Haiku 4.5; never substitute a larger model. Keep test homes and sessions isolated. Never use an existing user pane, start a second writer on a user thread, or modify personal config. The replay owns all panes it types into.

## Launch and identify

Start the installed CLI inside a newly created real Graffitty pane in an empty test directory. Require a fresh session ID, an assistant-only READY response and idle state. Read the recorded model identity; a different model fails. Codex daemon discovery must use its PID-owned listener, with no launch context or title configuration.

## Native delivery

Connect Send edges and send a unique reply marker through the graph. Native acceptance alone is insufficient: require an assistant transcript response and idle. Place an unsent draft in the recipient and verify it survives. Cross-provider runs exercise Codex → Claude and Claude → Codex. Never infer model completion from prompt text or terminal rendering.

## Mute and reconnect

Mute, then disconnect the edge; sends must be rejected immediately. Restore the edge and deliver a new marker. Require the same session UUID and a fresh assistant response.

## Evidence and result

Retain report.json, replay.log and evidence.json in the private run directory. Report PASS, FAIL or BLOCKED. Authentication, model access, unavailable sockets or denied process inspection are BLOCKED, never PASS. A receipt without an assistant response does not prove delivery completion. Live visual quality requires a separate windowed recording.
