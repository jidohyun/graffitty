# Pane identity inside tmux

`gft` and the Rust SDK claim the pane displaying them instead of trusting the
old pane token inherited from the tmux server. No manual claim is needed.

## Enable passthrough

In `~/.tmux.conf`:

```tmux
set -g allow-passthrough all
```

Use `all` so background tmux panes can claim too. Attach each tmux session from
only one Graffitty pane at a time.

## If a request fails

| Failure | Check |
| --- | --- |
| Passthrough disabled or claim timeout | Reload tmux configuration; use `all` rather than visible-only `on` |
| Ambiguous claim | Detach duplicate clients displaying the same tmux session |
| Old server rejected | Restart that tmux server under the current Graffitty server |
| No controlling terminal | Run the process from its tmux pane |

A long-running node keeps the pane it claimed at startup.
Nested tmux and SSH are outside this claim path.

## Implement another client

Use [the protocol](pane-claim-protocol.md) for nonce/ticket handling and error codes.
A client reading pane variables directly must run outside tmux or implement claims.
The server validates tickets, expiry, and capabilities; pane claims are not an OS sandbox.
