# Markdown preview

Use [markdown-preview.nvim](https://github.com/selimacerbas/markdown-preview.nvim)
to preview Markdown from Neovim in Graffitty's built-in Chromium.

- Opens the preview beside Neovim.
- Optional [graffitty.nvim](https://github.com/graffitty/graffitty.nvim) holds keep the editor still.
- Without graffitty.nvim, previewing still works.

Add this to your lazy.nvim plugins:

```lua
{
  "selimacerbas/markdown-preview.nvim",
  version = "v1.10.0",
  dependencies = { { "selimacerbas/live-server.nvim", version = "v1.5.0" } },
  config = function()
    local mp = require("markdown_preview")
    mp.setup({
      open_browser = true,
      browser = vim.env.TERM_PROGRAM == "graffitty" and vim.env.GRAFFITTY_BIN and {
        vim.env.GRAFFITTY_BIN,
        "chromium", "new", "--url",
      } or nil,
    })
  end,
}
```

Run `:MarkdownPreview` in a Markdown buffer to open the preview inside the
terminal; `:MarkdownPreviewStop` closes it. The optional hold restores effects too. Outside
Graffitty, the plugin uses your default browser and the hold is a no-op.

## Optional: pause editor effects

Add this inside `config = function()`, after `mp.setup(...)`:

```lua
-- Keep the editor still while the preview is open.
    local has_effects, effects = pcall(require, "graffitty.effects")
    if has_effects then
      local start, stop = mp.start, mp.stop
      mp.start = function(...)
        effects.hold("markdown-preview", { off = { "typing", "sparks" } })
        return start(...)
      end
      mp.stop = function(...)
        effects.release("markdown-preview")
        return stop(...)
      end
    end
```

`off` takes any effect names or groups, for example `"all"` with
`on = "cursor_trail"` to keep only the cursor trail. The hold applies while the
Neovim pane is focused; focusing the Chromium pane releases it, and focusing
back restores it.
