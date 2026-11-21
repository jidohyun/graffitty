# Filetree

Browse files beside a terminal, then open them in an attached editor or browser.

## Open and use

- Click the folder-tree button on a pane, or press **prefix, Tab**.
- Press **prefix, Backspace** to open and focus the tree.
- The tree follows the connected terminal's directory, staying at the Git project root while you navigate inside it.

## Keys

| Key | Action |
| --- | --- |
| **Enter** or double-click | Expand a folder or open a file |
| **Backspace** | Collapse a folder |
| `h` / `l` | Move through filenames for editing |
| **U** | Go to the parent root (`u` remains undo) |
| `-` / `_` | Send the selected path with / without Enter |
| `cd` | Change the connected terminal's directory |

Unsaved filetree edits pause directory following until saved.

## Opened files

- **Images, PDF, HTML, audio, video:** open in an attached browser; additional files use tabs. The browser also handles XHTML, animated PNG, JPEG variants, and media containers such as QuickTime (MOV), Matroska (MKV/MKA), and WebM audio (WEBA). Playback depends on the container and codecs supported by the browser build.
- **Other files:** open in an attached Neovim viewer with your normal editor configuration.
- **No Neovim installed:** the bundled Neovim opens with clean defaults.
- Closing the tree leaves its viewers open, preserving their buffers and tabs.
- Closing the original terminal closes its tree, but leaves the viewer open.

## Bundled filetree (default)

Neovim, Fyler, icons, and Git status are included. The tree uses an isolated
configuration and removes temporary state on close. App upgrades replace the bundle.

A thin scrollbar on the tree's right edge shows where you are in a long
listing; drag it to scroll. It has its own column, so it never covers a name.

## Customize the tree

Keep the bundled tree unless you need your own Neovim setup.

### Custom filetree command

Set this on the **server computer**, in `server.toml`:

```toml
[filetree]
command = ["nvim", "-u", "/absolute/path/to/init.lua"]

[filetree.environment]
NVIM_APPNAME = "nvim-filetree"
```

- `command`: executable followed by literal arguments; use absolute paths instead of `~`.
- A bare executable name searches the server's `PATH`.
- `NVIM_APPNAME` separates the tree's config and data from your usual editor.
- Without `-u`, Neovim loads the selected app-name configuration.
- Your config manages its plugins; it is not isolated like the bundled tree.
- Restart the server to apply changes. Remove `command` to return to the bundle.

Use the [bundled setup](https://github.com/graffitty/graffitty/blob/main/apps/server/filetree/init.lua) as a starting point for Fyler and its Graffitty integrations.

### Framing the filetree with its pane

Adaptive zoom can keep the tree and its connected pane visible together.
Set the `filetree` relation in [adaptive framing](../customize/typing-effects.md#framing-related-panes-together):

- Default `0.25`: include nearby trees.
- `false`: frame only the focused pane.

### Holding effects while a filetree is open

To keep the workspace still while browsing, set this in `server.toml`:

```toml
[filetree]
hold_effects = ["pane_zoom", "camera"]
```

The effects stay off in the tree and its connected pane until the tree closes.
See [effect selectors](../developers/automation-and-extensions/effect-holds.md) for other choices.
