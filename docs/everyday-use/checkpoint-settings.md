# Checkpoint settings

For saving and restoring, start with [Checkpoints](checkpoints.md).

## Automatic checkpoints

Enabled by default, even with no frontend connected. The server saves:

- About **10 seconds** after tabs, panes, layout, directories, titles, or graph
  connections change and settle; at most once a minute.
- When an agent session starts or ends.
- When it shuts down, within 5 seconds. Programs the system has already ended
  cannot be saved, so the previous save stays the newest.
- Every **30 minutes** otherwise.

A save that changed nothing writes no entry. History entries stay at least
**30 minutes** apart: until then a new save replaces the newest entry. The
latest **20** automatic checkpoints are kept, separately from manual saves, so
they cover at least 10 hours of changes.

Change these defaults in `~/.config/graffitty/server.toml`:

```toml
[checkpoints]
enabled = true
interval_seconds = 1800
history = 20
```

`interval_seconds` sets both the timer and the spacing between history entries.

Apply changes with a [server restart](../customize/server-configuration.md#reload-server-configuration).

## Choose an older checkpoint

```sh
gft checkpoint list --tag auto
gft checkpoint restore --tag auto --checkpoint 2
```

History indices start at **0** for the newest entry; `2` is the third newest.
Omit `--tag auto` for manual history.

## Choose storage

Checkpoint history and imported files use different trust rules.

- Default folder: `~/.local/state/graffitty/checkpoints`.
- `XDG_STATE_HOME` changes the state directory; `GRAFFITTY_CHECKPOINT_DIR` overrides the checkpoint folder directly.
- Manual history defaults to 20 entries; set `GRAFFITTY_CHECKPOINT_HISTORY` to change it.
- Automatic history uses `[checkpoints].history`.
- Files use private permissions and do not store secret values.

## Import a checkpoint

To open a checkpoint file:

```sh
gft checkpoint restore --checkpoint /absolute/path/checkpoint.json
```

Only checkpoints in local history may relaunch saved commands.
Imported checkpoints restore those panes as shells and report the skipped commands, so opening someone else's layout does not execute their programs.

## Add a save shortcut

In `client.toml`:

```toml
[bindings]
SaveCheckpoint = "CmdOrCtrlShift+S"
```
