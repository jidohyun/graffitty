# Open in Graffitty

Open a local folder in a new Graffitty window from your file manager.

## macOS Finder

Right-click a folder → **Services → Open in Graffitty**.

- Included with the installed app.
- If hidden, enable **System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders → Open in Graffitty**.
- To open the current folder, select it in Finder's path bar or its parent folder.
- After replacing the app, logout/login may be needed to refresh Services.

## Windows Explorer

Right-click a folder, drive or folder background → **Open in Graffitty**.

- On Windows 11, choose **Show more options** first.
- The install command enables the action.
- No administrator access is required.

To add it again by hand, run this in `%LOCALAPPDATA%\Programs\Graffitty`:

```powershell
.\install-context-menu.ps1
```

Remove the entry before deleting Graffitty:

```powershell
.\install-context-menu.ps1 -Uninstall
```

If Windows blocks the script, review it, then use `Unblock-File .\install-context-menu.ps1`.

## Linux

The [installer](../start-here/install.md#linux-and-macos) registers the supported actions.

| File manager | Menu |
| --- | --- |
| Dolphin | Open in Graffitty |
| Nautilus / GNOME Files | Scripts → Open in Graffitty |
| Nemo | Scripts → Open in Graffitty |

- Select a folder first in Nautilus or Nemo.
- Dolphin may require enabling the action under **Settings → Configure Dolphin → Context Menu**.
- Restart the file manager if the entry does not appear.

### Register again

```sh
python3 ~/.local/share/graffitty/installs/current/install.py \
  --launcher ~/.local/share/graffitty/installs/current/gft-gui --exported
```

Use the `current` path so upgrades keep the entry working.

### Thunar

Under **Edit → Configure custom actions**, add:

| Field | Value |
| --- | --- |
| Name | `Open in Graffitty` |
| Command | `"/absolute/path/to/data/graffitty/open-folder" %F` |
| Pattern | `*` |
| File types | Directories only |

The helper normally lives at `~/.local/share/graffitty/open-folder`. Expand `~` to an absolute path; use `XDG_DATA_HOME` if customized.

### Remove Linux entries

```sh
python3 ~/.local/share/graffitty/installs/current/install.py --uninstall
```

Remove a manually configured Thunar action separately.
