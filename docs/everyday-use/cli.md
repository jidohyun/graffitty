# Command line

Run `gft` inside Graffitty to control your workspace. Use `gft-gui` to launch the app.
For options, run `gft --help` or `gft <command> --help`.

## Find and focus a pane

```sh
gft pane list
gft pane select -t %3
```

Replace `%3` with an ID from the listing.
Use `-L`, `-R`, `-U`, or `-D` to focus a neighboring pane, including floating panes.
For targets and editor integration, see [Select a pane](select-pane.md).

## Show an image

```sh
gft terminal icat photo.jpg
gft terminal icat --clear
```

Files, directories, URLs, and piped images work.
See [Image display](images.md) for size, alignment, SSH, and tmux options.

## Give an agent workspace instructions

Ask the agent to run one of these:

```sh
gft skill graph
gft skill chromium
```

`graph` covers workspace and agent controls; `chromium` covers browser automation.
`gft skill` lists all guides. These commands print instructions; they do not install skills.

## Capture or type text

```sh
gft terminal get-text --scrollback > terminal.txt
gft terminal type -t %3 --text 'hello'
gft terminal send-key -t %3 Enter
```

Typing does not press Enter. See [Terminal commands](terminal-commands.md)
for capture behavior and remote targets.

## Save a layout or open files

| Task | Command or guide |
| --- | --- |
| Save the workspace | `gft checkpoint save` |
| Restore the latest manual save | `gft checkpoint restore`; see [Checkpoints](checkpoints.md) |
| Toggle the filetree | `gft filetree` |
| Open and focus the filetree | `gft filetree --focus` |
| Manage sessions | [Session commands](sessions.md#from-the-command-line) |
| Arrange panes | [Tabs and panes](workspaces.md#cli) |
| Connect agents | [Graph commands](../agents/connect-agents.md#from-the-command-line) |
| Run a tool node | [Automation nodes](../agents/automation.md) |

## Add shell completion

```sh
gft integrate completion install zsh
```

Replace `zsh` with `bash` or `fish`. Follow the printed setup instructions;
the command does not edit startup files. Use `--force` to replace an existing completion file.
