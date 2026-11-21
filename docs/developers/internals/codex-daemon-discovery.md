# Automatic Codex discovery

Graffitty identifies the exact Codex thread in a pane before delivering graph messages.
It uses the existing local daemon and native queue, without wrapping ordinary launches.

## How the match works

1. Find the foreground Codex process and its owned task-tool listener.
2. Read metadata for loaded main threads.
3. Require one thread whose task-server origin matches that listener.
4. Recheck the binding and process identity immediately before delivery.

Ambiguous or missing matches fail closed. Titles and the newest transcript are
not sufficient proof of identity.

## When incoming delivery is unavailable

- Local `--no-daemon` sessions have no external queue endpoint.
- Remote daemons and incompatible configurations are outside this local path.
- Daemon recovery can restore a conversation without restoring its TUI metadata.

For missing metadata, exit that Codex TUI and run `codex resume <thread-id>` in the
same Graffitty terminal. Restarting Graffitty alone does not repair the binding.

See [protocol and validation](codex-discovery-protocol.md) for source references,
authorization checks, and recorded tests.
