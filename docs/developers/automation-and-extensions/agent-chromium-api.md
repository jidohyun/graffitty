# Browser automation

Control a Chromium pane from an agent or script inside Graffitty.
To give an agent the instructions, ask it to run `gft skill chromium`.

## Open a page

```sh
gft chromium new --url http://localhost:3000
```

Copy the returned browser ID. The examples below use `%3`; replace it with yours.

## Inspect, then interact

```sh
gft chromium snapshot --target %3
```

Use the returned element references to fill or click:

```sh
gft chromium fill --target %3 --ref <snapshot-ref> --text hello
gft chromium click --target %3 --ref <snapshot-ref>
```

Replace `<snapshot-ref>` with a reference from your snapshot.
Commands return JSON; failures exit nonzero. Use `--help` for options.

## Recover when something changes

| Problem | Next step |
| --- | --- |
| `stale_ref` | Take a new snapshot and use its references |
| Page stops responding | Reload or navigate again |
| Browser process stops | Choose **Restart** in its pane |
| Target closes | Create or select a live browser |

Snapshots cover the main document, excluding cross-origin frames and closed
shadow roots. Commands do not switch targets automatically.
Restarting loses live page state; persistent profiles keep data already saved.

## Other interfaces

- [Playwright attachment](playwright-compatibility.md) borrows an existing page.
- `gft mcp` provides optional stdio MCP tools. Launch it in the agent's inherited
  workspace environment; do not save workspace tokens in global configuration.
- [Method reference](browser-methods.md) lists RPC fields.
- [Host API](browser-host-api.md) describes permissions and request envelopes.
