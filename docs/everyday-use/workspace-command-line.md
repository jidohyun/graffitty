# Workspace command line

Run workspace actions and jump to panes without opening a shell. The default prefix is **Ctrl+A**, released before the next key.

## Command line

Press **prefix, :** to run an action or jump to a tab, pane or session.

| Type | Result |
| --- | --- |
| `split right` | Find `SplitRight` |
| `2` | Select the second tab |
| `2.1` | Select its first pane |
| `%12` | Select pane ID 12, in any window |
| `@7` or `@7.1` | Select tab ID 7 or its first pane |
| `$work` | Switch to live session `work` on the selected server |

- **Up/Down** or **Tab/Shift+Tab:** select a result.
- **Enter:** run it. Approximate matches need an explicit selection first.
- **Escape:** close.
- **Prefix, digit / % / @ / $:** open directly in that navigation mode.
