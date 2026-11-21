# Read and send terminal text

Use pane IDs from `gft pane list`. Commands address the pane without changing frontend focus.

## Capture and type

Save the current screen or include scrollback:

```sh
gft terminal get-text
gft terminal get-text --scrollback > terminal.txt
gft terminal get-text -t %3 --json
```

Capture leaves focus and scroll position unchanged. Full-screen programs expose
their current screen, without the shell's earlier scrollback.

Type into another pane, then send a key:

```sh
gft terminal type -t %3 --text 'hello'
gft terminal send-key -t %3 Enter
```

Replace `%3` with an ID from `gft pane list`. Typing does not press Enter.
Keys can include modifiers, such as `Ctrl+h`; add `--no-effects` to `send-key`
to suppress typing effects.

## Control a remote terminal

Connect using an SSH host from your configuration and choose a CLI alias:

```sh
gft remote connect build-server --alias build
gft pane list -t build/
```

Use a qualified target from the listing for input or capture:

```sh
gft terminal type -t 'build/%12' --text 'hello'
gft terminal send-key -t 'build/%12' Enter
gft terminal get-text -t 'build/%12'
```

The connection must stay open. Add `--no-gui` to connect without opening a window;
Telegram verification requires the GUI. See [remote access](../remote-access/index.md).
