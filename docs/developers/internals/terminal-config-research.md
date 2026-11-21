# Terminal configuration research

External emulator references reviewed during configuration design. They do not define Graffitty settings.

## Sources reviewed

- [WezTerm options](https://wezterm.org/config/lua/config/index.html): fonts,
  line/cell metrics, palettes, selection, scrollback, shell/environment, keyboard
  actions and separate window configuration.
- [WezTerm default keys](https://github.com/wezterm/wezterm/blob/main/docs/config/default-keys.md)
  and [Quick Select](https://wezterm.org/quickselect.html): Ctrl+Shift+F for search,
  Ctrl+Shift+Space for quick select; configurable action bindings.
- [Ghostty options](https://ghostty.org/docs/config/reference) and
  [actions](https://ghostty.org/docs/config/keybind/reference): font faces,
  background opacity, cursor/selection, scrollback budget, image limits,
  clipboard policy, and keybind scopes. Its scrollback budget is not the same
  unit as Graffitty's line count.
- [Kitty configuration](https://sw.kovidgoyal.net/kitty/conf/): explicit palette
  entries, text/cell layout, opacity, shell integration, clipboard controls,
  keyboard actions, and user-defined native menu placement.
