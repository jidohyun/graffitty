# Copy, search, and navigate

Press **Ctrl+Shift+F** to search terminal output. Press **Esc** to leave.

## Copy text with the keyboard

1. Press **Ctrl+Shift+X** to open copy mode.
2. Move with the arrow keys.
3. Press **v** to start selecting.
4. Move to the end of the text.
5. Press **y** to copy and leave.

For more motions, see [Copy mode keys](copy-mode.md).

## Find something quickly

| Task | Shortcut |
| --- | --- |
| Search output | **Ctrl+Shift+F** |
| Select a URL, path, or other recognized item | **Ctrl+Shift+Space**; see [Quick Select](quick-select.md) |
| Copy the last completed command's output | **Ctrl+Shift+O** |
| Move between shell prompts | **Shift+Up / Down** |

Command-output copying and prompt navigation require shell integration. It is
installed automatically for supported local shells.

Search, copy mode, and Quick Select hold the displayed output still. Your program
keeps running. Leaving the mode shows the new output; press **r** in copy mode
to refresh sooner.

## Open a link

**Ctrl-click** or **Cmd-click** a link to open it. Hover to see its destination.

Right-click a link to copy its address, open it in your device's browser, or
show it in a Graffitty Chromium pane. The Chromium pane runs on the terminal's
server. Remote clients can copy non-web links but cannot open them.

## Integrate a shell or application

See [shell integration and terminal protocols](../developers/automation-and-extensions/terminal-integration.md)
for remote shell setup, clipboard permissions, and application integration.
