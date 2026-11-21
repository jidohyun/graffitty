# Codex discovery protocol and validation

Verified against Codex revision `65c3f40bef`, **2026-09-29**.
The join uses process-owned task-tool listeners and daemon metadata, without
invoking MCP tools, reading bearer tokens, scraping titles, or resuming threads.

## Match a process to a thread

1. Find the foreground Codex PID in the pane's process tree.
2. Find its owned `127.0.0.1` listening ports:
   - macOS: `lsof -n -P -a -p PID -iTCP -sTCP:LISTEN -Fn`.
   - Linux: intersect socket inodes in `/proc/PID/fd` with LISTEN rows in
     `/proc/PID/net/tcp`; the TCP table alone does not establish ownership.
3. Connect to the existing local daemon socket; do not start a server or resume threads.
4. `thread/loaded/list`, then `thread/read` with `includeTurns: false`.
5. Exclude ephemeral threads and subagents.
6. For each remaining thread, request:
   ```json
   {"method":"mcpServerStatus/list","params":{"threadId":"UUID","serverName":"codex_tui","detail":"toolsAndAuthOnly"}}
   ```
7. Match `data[].httpOrigin` to an owned port. Require exactly one main thread.
8. Repeat the binding check and process start identity check immediately before
   `thread/queue/add` or `thread/queue/delete`.



Reuse one inventory per Codex home per scan. Status/transcript paths come from
metadata-only reads. Exact `CODEX_THREAD_ID` lookup goes through `agent.context`
on the local server descriptor, using its private capability and worker scan.
Absent/ambiguous matches fail; inherited pane tokens are not a fallback.

## Source chain

Paths below are relative to the Codex repository:

- `codex-rs/tui/src/dynamic_tools_mcp.rs`: `DynamicToolMcpServer::start` binds
  `127.0.0.1:0`; `ThreadToolTransport::configure_mcp` inserts `mcp_servers.codex_tui`.
- `codex-rs/app-server-protocol/src/protocol/v2/mcp.rs`: `threadId`, `serverName`,
  and `httpOrigin` fields.
- `codex-rs/app-server/src/request_processors/mcp_processor.rs`: selected-server
  query and origin extraction from the thread's effective configuration.
- `codex-rs/codex-mcp/src/runtime/status.rs`: reads the published runtime and
  reuses the selected connection without starting unrelated servers.
- `codex-rs/app-server/tests/suite/v2/mcp_server_status.rs`:
  `mcp_server_status_list_reuses_thread_connection`.
- Commit `ea64727556` (2026-09-27), PR #48783, adds selected-server discovery.

## Limits and validation

| Situation | Result |
| --- | --- |
| Several main threads share a listener | Ambiguous; reject |
| Tools disabled / metadata unavailable | Cannot establish delivery binding |
| Remote daemon | Outside local discovery |
| `--no-daemon` | PID-owned rollout/locks can identify it; no native incoming queue |
| Daemon restart loses per-thread MCP config | TUI survives but binding cannot be proved |

For lost configuration, exit the affected TUI and `codex resume <thread-id>` in
its Graffitty pane. Restarting Graffitty alone cannot repair Codex metadata.

### Recovery design

Daemon recovery can continue an active thread before the TUI reconnects, ignoring
its configuration overrides. The proposed Codex correction is to persist per-thread
MCP overrides and reload them before automatic continuation, while reloading global
configuration/managed requirements. It is not a Graffitty fallback or a claimed fix.

### Recorded checks

| Check | Coverage |
| --- | --- |
| `tests/agents/codex_hooks_e2e.py daemon --graph` | Unwrapped TUI, daemon join/queue, draft preservation, resume guidance |
| `local`, `overrides` variants | PID/session discovery, unavailable delivery, native exit behavior |
| Socket-pair units | Metadata-only selected-server requests, subagent exclusion |
| Identity units | inode ownership, lsof parsing, origins, ambiguous matches |
| `tests/agents/test_agent_context.py` | Real owner/CLI, stale environment, exact thread/PID match, duplicates, closure, capabilities |

Runs use isolated homes and mock models. Recovery regression still needs idle and
interrupted threads with distinct authenticated endpoints, before reconnect overrides.
Ordinary launches remain unwrapped; obsolete proxy launch contexts are unsupported.
