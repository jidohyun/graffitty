# Development launches

```sh
mise run dev
```

If a session server is already running:

| Choice | Result |
| --- | --- |
| **1. Keep running** (default) | Keep the current server and programs. |
| **2. Restart server** | Save a checkpoint and restart without ending terminals. |
| **3. Restart terminals with new build** | Save a checkpoint, end existing sessions and programs, and open a fresh session. |

- Non-interactive launches keep the server running.
- Option 3 requires typing `RESTART`. Run it outside Graffitty so it cannot end its own launcher.
- A [checkpoint](../../everyday-use/checkpoints.md) can restore layouts and agent conversations, not running programs.
- Failed checkpoints or server handovers cancel the launch.

## Restart the server manually

Build or install to the running server's executable path first. Launching a development client does not switch an installed server to a development build.

```sh
gft checkpoint save
gft server restart
```

Existing terminals retain their process version. New terminals use the new build.
This works on macOS, Linux and Windows. Installers do the same through
[`gft internal update finish`](packaging.md#upgrades-keep-terminals-running).

## Reload GDScript

Requires a debug Godot build.

```sh
mise run dev:build
mise run dev -- --reload
```

| Change | Needed |
| --- | --- |
| GDScript methods | Reloaded automatically; member values stay |
| `_init`, `_ready`, control construction, shaders or assets | Restart the client |
| Rust or native code | Rebuild |

To enable reload for an existing client: detach its windows, launch with `--reload`, then reattach with `--workspace=NAME --attach-session`.
