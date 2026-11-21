# Filetree root title and toggle state

## Prepare real Fyler with a different root

Use an isolated server and the actual Fyler plugin. Set its Neovim profile in
`server.toml`, not client config. Keep the owner terminal in one directory and
open Fyler on another root, including a path containing spaces and `%`.

## Open with the header button

Click the owner's filetree header button. Confirm exactly one connected tree
opens, the button stays blue, and the tree title is its actual displayed root
rather than “Filetree” or the owner's cwd.

## Change Fyler root independently

Navigate to the parent root inside Fyler. Confirm the pane title updates to that
root while the owner shell's directory stays unchanged.

## Toggle off closes the pane

Click the owner's blue button again. Confirm the tree pane and its process close,
the button becomes inactive, and the owner's shell/process survives. Reopen and
close the tree using the pane close control; the owner's button must also reset.
