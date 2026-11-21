# CLI development

For everyday commands, see [Command line](../../everyday-use/cli.md): pane navigation, image
display, terminal input, bundled agent skills, and shell completions.

## Build and launch

```sh
mise run dev
```

| Task | Command |
| --- | --- |
| Build without installing or opening a window | `mise run cli:build` |
| Launch a custom world | `mise run dev -- --plugin=/absolute/path/custom-world.pck` |
| Rebuild CLI and server | `mise run core:build` |
| Run the headless server | `gft server` |

- Development binaries are staged in `dist/bin/` and installed to `~/.local/bin`.
- Keep `~/.local/bin` on PATH.
- `GRAFFITTY_GODOT` selects a custom Godot executable.
- See [development launches](development-launches.md) before restarting a running app or server.

## Change CLI behavior

### Command definitions

- `gft` runs the CLI; `gft-gui` launches the app.
- Commands, help and completions share a `usage-rs` specification.
- `gft __usage_spec__` exports the Usage KDL specification.
- Guide text and MCP schemas are embedded in the executable.
- MCP configuration: executable `GRAFFITTY_BIN`, arguments `["mcp"]`.

### Caller and target selection

- New terminals inherit their CLI path, socket, token, tab ID and pane ID.
- Use `"$GRAFFITTY_BIN"` to invoke the bundled CLI.
- Codex daemon shells resolve `CODEX_THREAD_ID` against live session evidence; ambiguous identities fail.
- tmux needs a [pane claim](../automation-and-extensions/pane-claim.md) because inherited pane IDs can be stale.

### Terminal API notes

- Input and capture run on the session server without changing GUI focus.
- RPC methods are `terminal.press` and `terminal.get_text`; text is in `result.text`.
- Paced input returns `keys_sent` when complete. Concurrent sequences on one terminal return `busy`; closing the terminal cancels input.

## Record a fixture

| Command | Behavior |
| --- | --- |
| `gft dev slack-send-demo` | Slack form with simulated delivery; no credentials or network |
| `gft dev codex-mock`, `gft dev claude-mock` | Scripted agent terminals without model calls |
| `gft dev systemone-mock` | Production routing UI with scripted decisions |

See [agent playback](../automation-and-extensions/agent-playback.md) for scenarios. Agent mocks execute configured commands only when `--real-tool-calling` is enabled.

## Validate

```sh
cargo test -p graffitty-cli icat::
cargo build -p graffitty-cli
python3 -m unittest discover -s tests/server -p test_icat.py -v
python3 -m unittest discover -s tests/server -p test_graffitty_cli.py -v
python3 -m unittest discover -s tests/godot -p test_effects_capture.py -v
```
