# Configuration

## Find a setting

| Change | Guide |
| --- | --- |
| Colors, cursor, selection, typing effects | [Terminal appearance](configuration-appearance.md) |
| Linux title bar and rounded window corners | [Window decorations](../everyday-use/multi-window.md#window-corners-and-decorations) |
| Desktop display scaling and the UI scale override | [Desktop UI scale](configuration-workspace.md#desktop-ui-scale) |
| Tiling, worlds, pane padding, transitions | [Workspace appearance](configuration-workspace.md) |
| Shortcuts, prefix, command palette, menus | [Keyboard and menus](configuration-keyboard.md) |
| On-screen keys and buttons | [Touch controls](../everyday-use/touch-controls.md) |
| File browsing and a custom editor | [Filetree](../everyday-use/filetree.md) |
| Microphone transcription | [Dictation](../everyday-use/dictation.md) |
| Shell, fonts, server defaults | [Server settings](server-configuration.md) |
| Browser logins | [Chromium profiles](chromium-profiles.md) |
| Neovim and tmux pane navigation | [Navigation setup](nvim-tmux-navigator.md) |
| JavaScript panels | [Mods](../developers/automation-and-extensions/mods.md) |

## Configuration files

- **Desktop:** `~/.config/graffitty/client.toml`.
- **Android:** `client.toml` in the app's private `config` directory.
- **Override:** `XDG_CONFIG_HOME` changes the configuration directory.
- **Server settings:** shells, fonts, dictation, navigation, and the filetree command belong in `server.toml` on the session host.

Validate before restarting:

```sh
gft-gui --check-config
```

## Layering and reload

| Priority, lowest first | Source |
| --- | --- |
| 1 | Built-in defaults |
| 2 | Automatic `client.toml`, unless `--no-config` |
| 3 | Explicit `--config=PATH.toml` files, in command order |

Later values win. Tables merge by key; arrays replace earlier arrays.
`--no-config` still allows explicit files. Worlds may override appearance.

| Change | Apply it |
| --- | --- |
| Client file | Validate, detach sessions to keep, then close the detached window and relaunch |
| Server file | [Save a checkpoint and restart the server](server-configuration.md#reload-server-configuration) |
| Fonts dialog | Immediate; no restart |

**Kill Session** ends the selected session and its programs.

## Interface language

- Choose **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Language**, or set `language = "ko"` at the top of `client.toml`.
- `"auto"` uses the device's system language.
- Each client keeps its choice when switching servers.

## Notifications

- **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Notifications:** open notification history.
- Hover a notification to pause dismissal.
- History keeps the last 1,000 notices until cleared or the app exits.

## Desktop file locations

| Kind | Default | Override base |
| --- | --- | --- |
| `config` | `~/.config/graffitty` | `XDG_CONFIG_HOME` |
| `data` | `~/.local/share/graffitty` | `XDG_DATA_HOME` |
| `cache` | `~/.cache/graffitty` | `XDG_CACHE_HOME` |
| `state` | `~/.local/state/graffitty` | `XDG_STATE_HOME` |

## Paths in client.toml

File paths (fonts, sounds, mods, worlds, and `SwitchWorld` menu items) may start
with `~/` or with one of the kinds above:

```toml
[world]
path = "%(data)/worlds/bistro/bistro.pck"
```

`%(config)`, `%(data)`, `%(cache)` and `%(state)` are the directories in the
table, including their overrides. Other relative font and mod paths resolve
beside the file that sets them.
