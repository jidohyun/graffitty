# Pane claim protocol

Use the CLI or Rust SDK when possible. Other clients implement the handshake
below to identify the pane displaying them inside tmux.

## Protocol

### 1. Authenticate the start request

Call `pane.claim.begin` with an existing pane capability.
The result contains `nonce`, `ticket`, and `timeout_ms`.

If the inherited token is unauthorized, use the private server descriptor only when:

- Its endpoint matches inherited `GRAFFITTY_SOCKET`.
- It is user-owned with no group/other permissions.

The descriptor is `~/.local/state/graffitty/server.json`, or the path in
`GRAFFITTY_SERVER_DESCRIPTOR`. Either capability starts a claim; neither selects its resulting pane.

### 2. Display the nonce

The nonce is 32 lowercase hex characters. Write it through tmux passthrough:

```text
ESC P tmux; ESC ESC ] 4723 ; claim=<nonce> BEL ESC \
```

tmux forwards `ESC ] 4723 ; claim=<nonce> BEL` to its displaying Graffitty pane.
The sequence is invisible. Keep the ticket private; the nonce alone grants no authority.

### 3. Finish the claim

Call `pane.claim.finish` with `{"ticket": ...}` and the same capability.
It waits for nonce observation, then returns `{"pane":"%N","token":...}`.
Use that token for subsequent requests.

Unknown, replayed, or expired nonces are ignored. Claims expire after two seconds.

## Errors

| Code | Check |
| --- | --- |
| `claim_timeout` | Passthrough; use `all` for hidden tmux panes |
| `ambiguous_claim` | Same tmux session attached from several Graffitty panes |
| `pane_closed` | Displaying pane closed during claim |
| `invalid_claim` | Ticket unknown or already finished |
| `busy` | 64 unfinished claims already exist |

`gft` checks `#{allow-passthrough}` before beginning and rejects `off` immediately.

## Related sequences

OSC 4723 also carries [effect holds](effect-holds.md), using the `effects` verb.
OSC 7501 is separate status reporting and needs no claim.
A claim proves output placement within the existing same-user trust boundary.
