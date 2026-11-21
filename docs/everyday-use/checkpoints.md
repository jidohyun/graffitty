# Checkpoints

Save a workspace so you can reopen its layout and resume agent conversations
after a crash. Restoring starts new processes; it cannot recover running memory,
terminal scrollback, or unsaved editor buffers.

## Save and restore

On desktop, open **Sessions**:

- **Save checkpoint** saves all windows and their positions.
- **Resume manual checkpoint** opens the saved workspace in new windows.
- **Save checkpoint and quit** quits after saving successfully.

Existing windows stay open during restore. These local menu actions are unavailable on Android.

From a Graffitty terminal:

```sh
gft checkpoint save
gft checkpoint list
gft checkpoint restore
```

CLI saves cover all sessions on the selected local server. Restore opens the
newest manual checkpoint by default. Window positions require a desktop menu save.

Restore is always something you start; Graffitty never restores by itself.

## Pane IDs stay the same

A restored pane, chromium, or tab keeps the ID it had when it was saved, so
`%7` still names the same pane in commands, scripts, and graph connections.

An ID that a live pane already has is replaced by a new one, for example when
you restore beside the original windows. `gft checkpoint restore` lists those
under `renumbered`. Imported checkpoint files always get new IDs.

## Know what comes back

| Restored | Left behind |
| --- | --- |
| Tabs, pane layout, names, directories | Running process state and scrollback |
| Agent conversation references | Transcript files; keep the originals |
| Graph connections and opted-in node state | Queued and in-flight messages |
| Filetree roots and placement | Expanded folders and unsaved buffers |
| Browser URLs and profile choice | Forms, scroll position, JavaScript state |

Claude, Codex, Pi, and OpenCode can resume saved conversations. Pi and OpenCode
need [agent integration](../agents/agent-setup.md). Unresolved programs reopen as shells.

Persistent browser profiles keep saved logins. Unavailable profiles fall back to
temporary storage; missing directories fall back to a surviving parent or home.
Missing worlds fall back to the built-in Flat world.

## Automatic saves and older checkpoints

Automatic checkpoints are enabled by default. The server saves about 10
seconds after the workspace changes, when an agent session starts or ends, and
once more when it shuts down. It keeps 20 entries separately from manual saves.

See [Checkpoint settings](checkpoint-settings.md) to change those defaults,
choose older entries, or import a checkpoint file. Imported files reopen saved
commands as shells; only local history may relaunch commands.
