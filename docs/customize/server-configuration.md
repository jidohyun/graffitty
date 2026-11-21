# Server settings

Edit `~/.config/graffitty/server.toml` (or `$XDG_CONFIG_HOME/graffitty/server.toml`).
These settings apply to the server, including its remote clients.

## Shell

```toml
[terminal]
shell = ["/bin/zsh"]
shell_integration = true

[terminal.environment]
EDITOR = "nvim"

[terminal.limits]
scrollback_bytes = 50000000 # 50 MB per terminal
```

- **Windows:** use `shell = ["pwsh.exe", "-NoLogo"]`.
- **Default shell:** your `SHELL` on Unix; PowerShell on Windows.
- **Login shell:** add `login_shell = false` to disable it on Unix.
- **New panes:** inherit the current pane's working directory.
- Shell and scrollback changes apply to new terminals.

## Fonts

Change fonts immediately with **Edit (<img class="menu-icon" src="../images/menu/square-pen.svg" alt="" width="18" height="18">) → Fonts**. No restart is needed.

To set the startup defaults in `server.toml`:

```toml
[terminal.font]
family = "JetBrainsMono Nerd Font Mono"
size = 16
fallbacks = ["Noto Sans CJK KR"]
line_height = 1.0
column_width = 1.0
ligatures = true
```

- Install fonts **on the server**. Remote clients download and cache missing fonts automatically.
- Omit `family` to use bundled JetBrains Mono Nerd Font.
- Omit `fallbacks` to choose an available CJK font automatically. Emoji and math fonts are bundled.

To use font files instead of an installed family:

```toml
[terminal.font]
paths = ["fonts/Regular.ttf", "fonts/Bold.ttf", "fonts/Italic.ttf", "fonts/BoldItalic.ttf"]
```

Paths are relative to `server.toml`. You can supply just the regular face.

## Other server preferences

### Automatic checkpoints

Enabled by default. See [checkpoints](../everyday-use/checkpoints.md) for what they can recover.

```toml
[checkpoints]
enabled = true
interval_seconds = 1800 # 30 minutes
history = 20
```

Workspace changes, agent session starts and ends, and server shutdown also trigger a save.
`interval_seconds` is also the least spacing between history entries; see [Checkpoint settings](../everyday-use/checkpoint-settings.md).

### CPU percentage

```toml
[resource_monitor]
cpu_percent_scale = "all_cores"
```

- `all_cores`: 100% means all cores are busy.
- `one_core`: 100% means one core is busy; four busy cores show 400%.

### Filetree

The default uses bundled Neovim. To use your own configuration:

```toml
[filetree]
command = ["nvim"]

[filetree.environment]
NVIM_APPNAME = "nvim-filetree"
```

See [Filetree](../everyday-use/filetree.md) for customization.

### Pane navigation

Enable Ctrl+H/J/K/L navigation from the shell and filetree:

```toml
[navigator]
enabled = true
filetree = true
algorithm = "spatial"

[navigator.bindings]
"ctrl+h" = "left"
"ctrl+j" = "down"
"ctrl+k" = "up"
"ctrl+l" = "right"
```

For navigation inside editors and tmux, see [Neovim and tmux](nvim-tmux-navigator.md).

## Reload server configuration

Changes made directly in `server.toml` load when the server starts. To reload it
while keeping terminals running:

```sh
gft checkpoint save
gft server restart
```

The new server keeps the old server's environment, not the environment of the
shell (or agent) that ran the command, so terminals opened afterwards look the
same as before the restart.

Save a [checkpoint](../everyday-use/checkpoints.md) first with `gft checkpoint save`.
After restarting, verify that the server returned and sessions survived.
If restart fails, do not kill the server or close sessions to work around it.
Font changes through the Fonts dialog apply immediately.

## Other settings

- [Chromium profiles](chromium-profiles.md): keep logins or start from a template.
- [Dictation](../everyday-use/dictation.md): configure a transcription provider.
- [Remote access](../remote-access/index.md): connect another device.
- [Full example](../examples/server.toml): additional limits, fonts, and environment overrides.
