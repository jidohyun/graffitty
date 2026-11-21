# Shell integration

Local Bash, Zsh, Fish, Nushell, and Elvish terminals load hooks automatically,
along with your existing startup files.

Hooks enable prompt navigation, command-output copying, and new panes starting
in the current directory. Elvish cannot reliably report the end of the prompt.

## Install hooks over SSH

Opening an SSH shell does not install hooks on that computer.
From a Graffitty repository checkout, preview the installation:

```sh
python3 tools/install_shell_integration.py --host user@host --shell zsh --dry-run
```

Replace the host and shell, then remove `--dry-run` to install.
The remote computer needs Python 3. The installer uses SSH authentication
and backs up the original startup file.

## Choose clipboard permissions

In `client.toml`:

```toml
[terminal]
clipboard_write = true
clipboard_read = "ask"
open_hyperlinks = true
```

Reads ask for permission by default. Use `deny` to block them or `allow` to
permit them. Arbitrary MIME clipboard data currently needs native macOS support;
other platforms expose plain text through Godot.

## Check the integration

Run a command, then try **Shift+Up** to jump to its prompt or **Ctrl+Shift+O**
to copy its output. Set `GRAFFITTY_SHELL_SKIP_CWD` to disable directory reports.

See [Copy, search, and navigate](../../everyday-use/terminal-integration.md) for
user controls, or [Terminal protocol reference](terminal-protocols.md) for
clipboard, image, notification, and application-control sequences.
