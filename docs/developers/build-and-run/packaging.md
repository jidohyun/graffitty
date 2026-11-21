# Packaging and releases

| Platform | Release guide | Bundle |
| --- | --- | --- |
| macOS | [Build the app](packaging-macos.md) | Apple Silicon app in a `tar.gz` |
| Linux | [Build release archives](packaging-linux.md) | One tarball per CPU |
| Windows | [Build the release archive](packaging-windows.md) | x64 `zip`, installed by `install.ps1` |

## Prepare

- Build on the target platform with matching Godot export templates.
- Restore the required DVC assets.
- On macOS and Windows, run `python3 tools/build_filetree_runtime.py` to stage Neovim and plugins. The Linux container does this itself.
- The build exports the pinned filetree plugins and generates Neovim's package lockfile. The bundled filetree loads those packages offline with `vim.pack`.
- Include licenses and source notices for bundled dependencies.

## Release checks

- Validate the complete bundle, including companion libraries and resources.
- Test an extracted or installed build on a clean target machine.
- Check terminal input, browser runtime, desktop integration, and signing where applicable.
- Publish checksums with the release assets.

## Publish a release

Installing and updating read one release listing, served by the website at
`https://graffitty.com/releases`:

| File | Holds |
| --- | --- |
| `latest.txt` | The latest release tag. A plain install and `gft self update` get this one. |
| `<tag>.txt` | One line per archive of that release: `<sha256>  <name>  <address>`. |

- `<name>` is the file an installer asks for, such as `graffitty-macos-arm64.tar.gz`.
- `<address>` is exactly where that file is: an https URL. Releases are published on this repository's GitHub releases, so it is `https://github.com/graffitty/graffitty/releases/download/<tag>/<name>`, which the tool fills in.

1. Build every archive with the same `GRAFFITTY_BUILD_VERSION`; each `gft --version` must equal the tag without its `v`.
2. Create the GitHub release tagged `v<version>` on this repository and upload the archives to it. The website cannot hold them: its host limits a file to 25 MiB.
3. Write the listing entry into the website checkout, then deploy the website:

```sh
python3 tools/release_listing.py --version v0.1.0 --latest \
  --output ../graffitty.com/public/releases \
  dist/graffitty-macos-arm64.tar.gz dist/graffitty-linux-*.tar.gz dist/installers/graffitty-windows-x64.zip
```

- The installers trust the checksums in the listing, so an archive can be stored anywhere, under any name, and moved by editing its address. `--archives <https folder>` names another folder for all of them, and `NAME=ADDRESS` after the files gives one archive its own address.
- GitHub serves release files publicly only from a public repository; until this one is public, the install commands cannot download them.
- A release is public once its file is deployed. Leave out `--latest` to publish a version only people who ask for it get.
- `GRAFFITTY_RELEASES` points the install scripts and `gft self update` at another listing: an https URL, or a local directory with the same layout, where an address may also be a path relative to that directory. Use it to install an archive you built.

### One installer for every version

`install.sh` and `install.ps1` are served by the website, and `gft self update`
runs that same current script. No release carries its own copy.

- A mistake in the installer is fixed for every user by publishing the script again.
- The script must therefore upgrade from every version ever released: keep each older layout's handling (a `gft` without `internal update prepare`, files an older version shipped) until no supported version needs it, and cover it in the script's tests.
- After changing a script, copy it into the website checkout with `bun run sync-install` there, then deploy.

## Upgrades keep terminals running

Every install script ends by running the installed `gft internal update finish`. Terminals
live in holder processes, so replacing Graffitty does not end them:

| Step | macOS and Linux | Windows |
| --- | --- | --- |
| Before replacing files | Nothing: running processes keep their old files. | `gft internal update prepare` (the installed version's): saves a checkpoint, tells windows to leave, lets the server exit while holders keep the terminals, and moves files a holder still runs from aside (`*.old-*`). |
| Replace files | macOS: `Graffitty.app` renamed into place. Linux: a new version directory and the `current` link. | `install.ps1` copies the unpacked archive over the installed files, after checking that none is in use, and deletes installed files the new version no longer ships. |
| `gft internal update finish` | Saves a checkpoint and restarts the server as the installed version; open windows reopen. | Starts the installed server, which adopts the terminals, and reopens the windows that were closed. |

- `finish` does nothing when no server runs or the server already runs the installed build, so it is safe to run twice.
- A holder from the previous version keeps its terminals until they end, then exits; new terminals use the installed version's holder.
- Holder sockets (`server.holder.<id>.sock`) and logs sit beside the server descriptor in the state directory. A Unix socket path is limited to about 104 bytes (macOS) or 108 (Linux, Windows), so a state directory deeper than about 75 bytes cannot start a holder; the server reports the path instead of moving the sockets elsewhere.
- If `prepare` cannot park (a window does not leave, a file cannot be moved aside), it restores the server and fails; the install script stops without changing anything.
- A Linux server, and the `gft` its terminals call, address the installation through the `current` link so they follow the upgrade.

| Test | Covers |
| --- | --- |
| `tests/server/test_terminal_holder.py` | macOS and Linux: restart, park and resume, versioned directories, and `install.sh` upgrading a running server twice. |
| `tests/platform/windows/windows_terminal_holder.py` | Windows: restart, park, replacing a locked executable, resume. |
| `tests/godot/update_relaunch_e2e.py` | A development window reopening after an update. |
| `tests/platform/macos/macos_install_script_e2e.py` | `install.sh` on macOS: install, then upgrade a running packaged app. |
| `packaging/windows/test_install.ps1` | `install.ps1` on Windows with downloads and `gft` mocked: install, upgrade a running app, failed hand-over, a file in use. |
| `tests/platform/windows/windows_installer_upgrade.py` | The unpublished Inno Setup installer upgrading a running installed app. Needs the desktop and a test-identity installer. |
| `packaging/linux/test_installer.py` | The Linux installer against fixtures. |

Bundles depend on the operating system's libc, graphics drivers, and desktop
services. Unit tests do not replace testing on the supported OS baseline.

See [file-manager integration](../../customize/file-manager.md) for folder actions.
