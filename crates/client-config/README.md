# Client configuration core

Frontend-independent Rust types for the `client.toml` implementation.

## Input bindings

```toml
[prefix]
key = "Ctrl+A"

[bindings]
NewTab = ["CmdOrCtrlShift+T", "Prefix+C"]
FocusLeft = "Prefix+H"
NewPaneRight = "Prefix+Backslash"
Copy = "CmdOrCtrlShift+C"
```

- Public action identities are PascalCase, not derived from translated menu labels.
- `CmdOrCtrlShift`: Command on macOS/iOS; Ctrl+Shift elsewhere.
- `CmdOrCtrl`: Command on macOS/iOS; Ctrl elsewhere.
- `Prefix` marks a two-step sequence, not a held physical modifier.
- Prefix keys accept strings or per-OS maps. Action bindings accept strings,
  arrays, or per-OS maps of either. OS names are `macos`, `windows`, `linux`,
  `android`, and `ios`.
- An omitted action or OS entry retains defaults; an empty binding array
  explicitly unbinds an action. An omitted OS prefix uses `Ctrl+A`.
- Shortcut modifiers are `Cmd`, `Ctrl`, `Alt`, `Shift`, `CmdOrCtrl`, and `CmdOrCtrlShift`.
  Letters are uppercase; punctuation uses named keys such as `Backslash` or
  `Plus` so `+` remains an unambiguous modifier separator.
- Resolution detects duplicate and conflicting bindings, including collisions
  with defaults, the prefix trigger, and reserved prefix controls/selectors.
- `ResolvedBindings` supplies both dispatch lookup and action shortcut hints;
  neither menus nor command completion should maintain a second binding map.
- Validation checks inactive OS branches too. Defaults must additionally be
  validated during per-platform resolution.

Run `cargo test -p graffitty-client-config`.
