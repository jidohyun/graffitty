# Make it yours

Start with the **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">)** menu:

- **World:** change the workspace's appearance.
- **Effects Profile:** adjust typing animations.
- **Resource Monitor:** show CPU and memory usage.
- **Agent sounds:** turn alerts on or off.

## Save your preferences

In `~/.config/graffitty/client.toml`:

```toml
[terminal.background]
color = "#282c34"
alpha = 0.85

[tiling]
gap = 12

[prefix]
key = "Ctrl+A"
```

Validate with `gft-gui --check-config`. Detach sessions you want to keep,
close the detached window, then relaunch. **Kill Session** ends the selected session and its programs.

- `gap = 0`: no space between panes.

## Find a setting

| Change | Where to look |
| --- | --- |
| Colors, cursor and terminal appearance | [Terminal settings](terminal-settings.md#terminal-config) |
| Keyboard shortcuts | [Key bindings](configuration-keyboard.md#change-a-shortcut) |
| Typing particles and pane zoom | [Typing effects](typing-effects.md#typing-particles-and-pane-zoom) |
| Interface language | [Language](configuration.md#interface-language) |
| Shell and starting directory | [Shell defaults](server-configuration.md#shell) / [Starting directories](../everyday-use/workspaces.md#starting-directories) |
| Fonts and text size | [Fonts](server-configuration.md#fonts) |
| Chromium profiles and logins | [Chromium profiles](chromium-profiles.md) |
| Agent notification sounds | [Agent sounds](../agents/agents.md#client-only-sound-configuration) |

Shell and font defaults live in `~/.config/graffitty/server.toml` on the computer
running your sessions. Appearance and shortcuts belong to the device you are using.
For all options, see the [configuration reference](configuration.md).
