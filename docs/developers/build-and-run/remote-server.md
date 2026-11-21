# SSH server deployment

Build a bundle for the destination computer before using `gft remote connect`.
For user setup, see [remote access](../../remote-access/index.md).

## Build a bundle

```sh
mise run cli:build
mise run server:bundle
```

- Build on the destination platform, or a matching VM/CI runner.
- Output: `dist/remote/<os>-<arch>/`.
- Copy that folder into the client's `dist/remote/`.
- The CLI selects the matching OS/CPU bundle; it does not download a substitute.

```sh
dist/bin/gft remote connect user@computer
```

Or provide an executable built for the destination:

```sh
gft remote connect build-server --server-binary /path/to/gft
```

## Install the bundle

- Linux/macOS: binaries under `~/.local/lib/graffitty/`; descriptor and log under `~/.local/state/graffitty/`.
- Windows OpenSSH: bundles under `%LOCALAPPDATA%\graffitty\bin`; descriptor under `%LOCALAPPDATA%\graffitty\state`.
- Connections use normal OpenSSH authentication and host-key checking.
- Existing daemons are reused; uploading a bundle does not replace a running daemon.
- Plan upgrades separately from connecting. Do not kill a server with live sessions just to deploy a bundle.
- Hosts that terminate user processes on logout need a service/session policy allowing persistence.

## One server per user

`gft server` without `--connection` and the app use the same descriptor:
`server.json` in the state directory (`$XDG_STATE_HOME/graffitty`, else
`~/.local/state/graffitty`, or `%LOCALAPPDATA%\graffitty` on Windows).

- The app attaches to a server already running there; it starts one only when none answers.
- A second `gft server` for the same descriptor is refused.
- If the `[remote]` address in `server.toml` is taken, the server still runs for this computer with remote access off. Its log and the app name what holds the address: another Graffitty server, or the program and its process number.
- An address given with `--listen` is the reason that server was started, so a taken one is fatal, with the same explanation.

## Keep a tunnel without opening a GUI

Complete any required Telegram code through a GUI connection first.

```sh
gft remote connect build-server --no-gui
```

- Keep the command running.
- Open its printed connection file with `gft-gui -- --remote-connections=PATH`.
- Ctrl+C closes the tunnel without stopping the remote server.
- Treat temporary connection files as secrets.

## Headless authentication

These commands save settings and exit; they do not start a listener:

```sh
gft server --set-password
gft server --temporary-password-length 8
gft server --telegram-credential graffitty-2fa --telegram-chat-id 123
gft server --telegram-credential off
gft server --clear-password
```

- `--set-password` uses a hidden local prompt.
- `--clear-password` returns to temporary passwords.
- Use `--auth-file PATH` for independent server credentials.
- Restart an already-running server to apply changes.
- Authentication state stores a password verifier, not the password. See [encryption and its limits](../../remote-access/connection-settings.md#understand-encryption) for transport protection.
