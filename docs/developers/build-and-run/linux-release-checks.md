# Linux release checks

Use this after [building a Linux bundle](packaging-linux.md). Build checks alone do not establish desktop or GPU acceptance.

## Validate

```sh
python3 packaging/linux/build_container.py --check
```

| Check | Recorded status |
| --- | --- |
| ARM64 image, 17 packaging tests and relocation fixture | Passed on Ubuntu 22.04 |
| ARM64 CLI/server, extension and AccessKit compilation | Passed |
| Seven headless terminal-scene tests | Passed against the CLI |
| ABI checks | CLI requires glibc ≤2.35 |
| Complete exports and desktop acceptance | Unverified |
| x86_64 | Not yet exercised |

Earlier Colima relocation and cached-binary checks validate the layout approach, not current-source releases. Container checks do not establish GPU-driver or minimum-kernel support.

## Publish

1. Test the extracted bundle on a clean target desktop.
2. Verify launch, terminal input/IME, dock grouping and browser panes (Chromium).
3. Include licences and required redistribution notices.
4. Upload archives with a top-level `SHA256SUMS` covering **every release asset**.
5. Follow the [Linux installation guide](../../start-here/install.md#linux-and-macos) to test the public installer.

Do not overwrite checksum entries for Windows or macOS when adding Linux assets.

## Install layout

- Versions live under `~/.local/share/graffitty/installs/`.
- The `current` symlink changes only after verification, so running apps keep their current files.
- Commands live in `~/.local/bin/`.
- User data stays outside version directories.
- The installer registers desktop and file-manager entries without root access. The application menu resolves `Icon=graffitty` from the per-user hicolor theme under `$XDG_DATA_HOME/icons` (default `~/.local/share/icons`).

### Uninstall

```sh
python3 ~/.local/share/graffitty/installs/current/install.py --uninstall
rm -rf ~/.local/share/graffitty/installs
rm -f ~/.local/share/applications/Graffitty.desktop ~/.local/bin/gft ~/.local/bin/gft-gui
find "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" -type l -path '*/apps/graffitty.png' -delete
```
