# Key binding reference

Edit `client.toml`. See [Keyboard and menus](configuration-keyboard.md) for first examples.

## Per-platform shortcuts

```toml
[bindings]
FocusLeft = { macos = "Alt+H", windows = "Ctrl+Alt+H" }
```

Platforms: `macos`, `windows`, `linux`, `android`, `ios`. Omitted platforms keep their defaults.

## Actions to bind

| Task | Action names |
| --- | --- |
| Tabs | `NewTab`, `NextTab`, `PreviousTab`, `SelectTab1`–`SelectTab9`, `OpenTabMenu`, `CloseTab` |
| Panes | `SplitRight`, `SplitDown`, `SplitLeft`, `SplitUp`, `ClosePane`, `RenamePane` |
| Focus | `FocusLeft`, `FocusDown`, `FocusUp`, `FocusRight` |
| Fit panes | `FitPane`, `FitMainArea`, `ResizeToFitMain` |
| Windows and sessions | `NewWindow`, `CloseWindow`, `NewSession`, `NextSession`, `PreviousSession`, `LastSession`, `SelectSession1`–`SelectSession9`, `CloseSession` |
| Agents | `NextAgent`, `PreviousAgent` |
| Side panels | `ToggleSidePanels`, `ToggleFiletree`, `ToggleFiletreeFocus`, `StatusLine` |
| Browser | `NewChromium` |
| Copy and search | `Copy`, `Paste`, `Search`, `QuickSelect`, `CopyMode`, `CopyLastOutput` |
| Prompts | `PreviousPrompt`, `NextPrompt` |
| Scroll | `ScrollPageUp`, `ScrollPageDown`, `ScrollTop`, `ScrollBottom` |
| Font size | `IncreaseFontSize`, `DecreaseFontSize`, `ResetFontSize` |
| Effects | `SettleEffects`, `ReleaseEffectHolds` |
| Checkpoints | `SaveCheckpoint`, `SaveCheckpointAndQuit` |
| Diagnostics | `ShowPaneStatus`, `ShowResourceMonitor`, `ShowMessages`, `ShowNotifications`, `ShowInfo` |

`CloseTab` closes the active tab and its panes. `CloseSession` asks before
ending the active session and all its tabs.

Session shortcuts use Command+Option on Apple platforms and Ctrl+Shift+Alt elsewhere.
Use the brackets to cycle through the current computer’s sessions. Use 1–8 to select
a session by its position on that computer and 9 to select its final session.
These shortcuts also work on remote computers. A missing destination consumes the shortcut.

## Sending text and ignoring keys

```toml
[bindings]
SendText = [
  { key = "Shift+Enter", text = "\u001b\r" },
  { key = "Cmd+Left", text = "\u0001" },
]
Ignore = ["F1"]
```

- `SendText` sends the specified text to the focused terminal.
- `Ignore` discards the key. Unlike `[]`, it does not pass it to the terminal.
- Both use direct shortcuts, not prefix sequences.

## Conditional shortcuts

A false condition passes the key through to the terminal.

Use `when` to let a program handle the key while the condition is false.

```toml
[bindings]
PreviousPrompt = { key = "Shift+Up", when = "prompt" }
ScrollTop = { key = "Shift+Home", when = "!alt_screen" }
```

| Condition | Shortcut works when… |
| --- | --- |
| `prompt` | The shell is waiting for input; requires shell integration |
| `alt_screen` | A program uses the alternate screen |
| `!alt_screen` | A program is not using the alternate screen |

- Applies to terminal actions, not app actions or prefix sequences.
- Prompt-jump shortcuts use `when = "prompt"` by default.
- Replacing a conditional binding with a plain string removes the condition.

## Menu action options

| Action | Extra fields |
| --- | --- |
| `SwitchWorld` | `path`: `"flat-2d"`, `"flat-3d"`, an installed world id, or a plugin path |
| `SetWorldSetting` | `world`: world id; `setting`: dotted key in `[worlds.<id>]`; `value`: string, number or boolean. See [world settings from the menu](world-settings.md#change-a-world-setting-from-the-menu) |
| `NewChromium` | Optional `url` and browser `profile` |
| `SetEffectsProfile` | `profile`: effects profile name |
| `OpenPanel` | `name`: registered [mod panel](../developers/automation-and-extensions/mods.md) ID |
| `SendText` | `text`: text to send |
| `Separator` | No extra fields |

Use `os = ["macos", "windows"]` to limit an entry to those platforms. Leave `os` out to show it everywhere.

See [running actions and jumping to panes](../everyday-use/workspace-command-line.md).
