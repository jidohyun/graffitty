# Neovim and tmux navigation

Use Ctrl-H/J/K/L to move through **Neovim splits → tmux panes → Graffitty
panes**. Each layer handles its own neighbors and passes navigation outward
only at an edge. Navigation never wraps.

Follow the setup below. If you do not use tmux, skip its setup.

## 1. Enable navigation in Graffitty

Enable navigation in `~/.config/graffitty/server.toml`:

```toml
[navigator]
enabled = true
filetree = true
algorithm = "spatial" # Alternatives: "weighted", "nearest"

[navigator.bindings]
"ctrl+h" = "left"
"ctrl+j" = "down"
"ctrl+k" = "up"
"ctrl+l" = "right"
```

Keep `gft` on PATH. This integration supports macOS and Linux.

## 2. Configure Neovim

Install [graffitty.nvim](https://github.com/graffitty/graffitty.nvim) with lazy.nvim:

```lua
{
  "graffitty/graffitty.nvim",
  opts = {},
  keys = {
    { "<C-h>", function() require("graffitty.navigator").move_left() end, desc = "Navigate left" },
    { "<C-j>", function() require("graffitty.navigator").move_down() end, desc = "Navigate down" },
    { "<C-k>", function() require("graffitty.navigator").move_up() end, desc = "Navigate up" },
    { "<C-l>", function() require("graffitty.navigator").move_right() end, desc = "Navigate right" },
  },
}
```

Normal mode is the default. To also navigate in insert and terminal modes, set
`opts.navigator.modes = { "n", "i", "t" }` and `mode = { "n", "i", "t" }`
on each mapping.

Neovim selects its own splits, then tmux neighbors, and invokes `gft pane select`
only at the outer edge. If you do not use tmux, skip the next section.

## 3. Configure tmux

Add the plugin before TPM initialization in `~/.tmux.conf`:

```tmux
set -g @plugin 'graffitty/tmux-graffitty'
run '~/.tmux/plugins/tpm/tpm'
```

Reload with `tmux source-file ~/.tmux.conf`, then press **prefix + I** to install.
Use **prefix + U** to update. Keep your existing TPM initialization line if present.

Without TPM, use the [manual tmux bindings](tmux-manual-navigation.md).

## Behavior

- Ctrl-H/J/K/L selects left/down/up/right respectively.
- Foreground applications retain their keys; Neovim handles its mappings.
- Copy mode keeps its keys, and a zoomed tmux pane stays zoomed.
- One tmux layer is supported. Plain SSH passes keys through without handing
  navigation back to local Graffitty.
- Outside Graffitty, Neovim and tmux navigation still work and stop at the edge.


## Send a navigation key literally

To pass a navigation key to the terminal instead, add this to `client.toml`:

```toml
[bindings]
SendLiteral = "Prefix+Ctrl+L"
```

The tmux bindings use `GRAFFITTY_BIN` when Graffitty supplies it.

To send a navigation key literally, press the Graffitty prefix, then Ctrl-L,
then the key.


## Select panes from a script

See [Select a pane](../everyday-use/select-pane.md) for directional and explicit CLI targets.
