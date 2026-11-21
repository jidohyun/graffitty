# Keyboard and menus

Edit `client.toml`; see [configuration](configuration.md) for its location.
Use [Keyboard shortcuts](../start-here/shortcuts.md) to look up the defaults.

## Change a shortcut

```toml
[bindings]
NewTab = "CmdOrCtrlShift+T"
SaveCheckpoint = "CmdOrCtrlShift+S"
```

`CmdOrCtrlShift` means **Command** on macOS/iOS and **Ctrl+Shift** elsewhere.
You can also use `Cmd`, `Ctrl`, `Alt`, and `Shift` directly.

An assignment replaces that action's defaults. To keep defaults, omit the action.
Each shortcut can belong to one action.

## Add several shortcuts or release a key

```toml
[bindings]
NewTab = ["CmdOrCtrlShift+T", "Prefix+C"]
Search = []
```

An array assigns several shortcuts. `[]` lets the terminal receive the action's
keys instead. Use names such as `Backslash`, `Minus`, and `Plus` for punctuation.

## Change the workspace prefix

The default is **Ctrl+A**: press it, release it, then press the action key.
For example, **prefix, C** opens a tab and **prefix, V** searches tabs and panes.

```toml
[prefix]
key = "Ctrl+B"
```

**Escape** cancels. Press the prefix twice to send it to the terminal.
The prefix's bare key, digits, `%`, `@`, `$`, and `:` are reserved for navigation
or passthrough.

## Add a menu item

```toml
[[menu.items]]
label = "View::Save checkpoint"
action = "SaveCheckpoint"
```

`::` creates submenus. A matching label replaces the built-in entry.
Menus display shortcuts from `[bindings]`.

See the [reference](keyboard-reference.md) for action names, per-platform bindings,
conditions, sending text, and menu options. Use the
[workspace command line](../everyday-use/workspace-command-line.md) to run actions without binding a key.
