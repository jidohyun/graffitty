# Windows packaging and install script

Windows releases are one archive, installed by a PowerShell script. Build the
archive, validate it, then publish the download command.

## Build a release

Prepare the Windows runtime bundle, then pack it:

```powershell
python packaging/windows/build_archive.py
```

This produces `dist/installers/graffitty-windows-x64.zip`, with every file under
a `Graffitty` folder, and adds its SHA-256 checksum to `SHA256SUMS` in the same
directory. Existing entries for other release assets are retained. Build assets
sequentially when sharing that directory.

Publish it as described in [Publish a release](packaging.md#publish-a-release).
A missing, duplicate or mismatched checksum in the release listing stops the
script before it unpacks anything. Use `GRAFFITTY_VERSION` to select a tag;
otherwise it reads the latest tag from the listing once. `GRAFFITTY_RELEASES`
names another listing, such as a local directory holding an archive you built.

```powershell
$env:GRAFFITTY_VERSION = 'v0.1.0'
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/install.ps1
```

The script requires PowerShell 5.1 or later and x64 Windows 10 1809 or later.
It needs no administrator access, never closes running applications on its own
and never reboots.

## What the script does

1. Downloads `SHA256SUMS` and the archive, and checks the archive against it.
2. Unpacks beside the destination and checks that the app and CLI are present.
3. If Graffitty is installed, runs its `gft internal update prepare`, which
   [parks a running Graffitty](packaging.md#upgrades-keep-terminals-running) so
   terminals keep running.
4. Checks that no installed file it would replace is in use. If one is, or if
   parking failed, it stops with nothing changed.
5. Copies the files into `%LOCALAPPDATA%\Programs\Graffitty`, the only
   installation, replaced in place, then deletes what an earlier version put
   there and this one no longer ships (dropped plugins and libraries, an
   external pack, files moved aside by an earlier upgrade). It touches nothing
   outside that directory: settings, sessions, passwords and worlds stay as
   they are. `unins*` from an installer-made copy is kept.
6. Grants Chromium's app containers read access to `chromium-windows`.
7. Creates the Start menu shortcut, registers **Open in Graffitty** in File
   Explorer with the bundle's `install-context-menu.ps1`, and adds the `tools`
   directory to the user `PATH` without replacing existing entries.
8. Runs `gft internal update finish` if it parked a running Graffitty, also
   after a failure.

Keep `packaging/install.ps1` ASCII only. Windows PowerShell 5.1 reads a script
file without a byte order mark in the system code page, and a byte order mark
breaks the piped download command. The shortcut's localized description is
therefore stored encoded.

There is no uninstaller. To remove Graffitty: close it, run the bundle's
`install-context-menu.ps1 -Uninstall` to remove the File Explorer entry, then
delete `%LOCALAPPDATA%\Programs\Graffitty` and the Start menu shortcut. The
`tools` entry stays in the user `PATH` until removed by hand.

## Publish the download command

The website serves the script itself at `https://graffitty.com/install.ps1`, as it
does `install.sh`, so the command does not depend on this repository being public.
The script still downloads the archive and `SHA256SUMS` from the GitHub release.

- This checkout owns `packaging/install.ps1` and tests it.
- After changing it, copy it into the website checkout with that checkout's
  `bun run sync-install`, then deploy the website.
- Verify that the URL returns the PowerShell script as plain text, not a redirect,
  before publishing the command to users.

## Validate

```powershell
pwsh -NoProfile -File packaging/windows/test_install.ps1
python -m unittest discover -s tests/platform/windows -p "test_windows_*.py" -v
```

The PowerShell checks need Windows. They mock downloads, `gft`, `icacls`, the
shortcut, the File Explorer entry and persistent PATH writes, and install only
under a temporary folder. They cover checksum rejection, an incomplete archive,
a fresh install, upgrading a running and an idle Graffitty, an older `gft`, a
failed hand-over, a file in use, cleanup, version selection and PATH
preservation. They do not establish a physical Windows install or upgrade pass.
Validate a real archive and the one-line download separately on Windows before
publishing a release.

## Inno Setup installer

`packaging/windows/build_installer.py --version 0.1.0` still compiles a per-user
Inno Setup installer (`Graffitty-0.1.0-windows-x64-setup.exe`) from the same
bundle. It is kept for a later release channel and is **not published**:
`install.ps1` does not download it.

See [Windows builds](windows-build.md) for runtime development and platform checks.

The Start menu opens the GUI-subsystem launcher `Graffitty.exe`. Godot and its embedded pack live in `GraffittyRuntime.exe`. Both files belong in the installer and ZIP. See [GPU startup](../internals/gpu-startup.md).
