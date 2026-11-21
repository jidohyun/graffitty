# Install Graffitty

## Linux and macOS

```sh
curl -fsSL https://graffitty.com/install.sh | sh
```

| | Linux | macOS |
| --- | --- | --- |
| **Requires** | x86_64 or arm64; glibc 2.35 or later (musl distributions such as Alpine are not supported) | Apple Silicon; macOS 12 or later |
| **Installs** | For your user under `~/.local`, without root access | `Graffitty.app` in `/Applications` |
| **Open** | Application menu, or `gft-gui` | Applications, or `gft-gui` |

- On Linux, replacing an existing build uses `mv --exchange` or Perl when the system has an older `mv`.
- **Command not found?** Add `~/.local/bin` to your `PATH`.
- **Browser panes on a headless Linux VM?** Run `gft server` as an ordinary user. With no desktop display or GPU, Chromium uses its bundled headless platform and renders panes for connected clients. Xvfb is unnecessary.

  On Ubuntu 22.04 or Debian 12, install the Chromium runtime libraries with:

  ```sh
  sudo apt install libnss3 libatk-bridge2.0-0 libcups2 libgbm1 libpango-1.0-0 libcairo2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxkbcommon0 libasound2
  ```

  On Ubuntu 24.04 or Debian 13, use:

  ```sh
  sudo apt install libnss3 libatk-bridge2.0-0t64 libcups2t64 libgbm1 libpango-1.0-0 libcairo2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxkbcommon0 libasound2t64
  ```

- **Cannot write to `/Applications`?** Set `GRAFFITTY_APP_DIR` to a folder you own, such as `~/Applications`, and run it again.

On macOS, Graffitty is not notarized by Apple. The script downloads with
`curl`, which leaves no quarantine flag, so the app launches without the
Gatekeeper warning; this does not mean Apple has checked the app.

## Windows

On x64 Windows 10 (version 1809 or later) or Windows 11, run:

```powershell
powershell -c "irm https://graffitty.com/install.ps1 | iex"
```

- **Installs:** for your user, without administrator access.
- **CLI:** added to your user `PATH`.
- **Open:** **Graffitty** in the Start menu, or `gft-gui` in a new terminal.

The script downloads `graffitty-windows-x64.zip` from the address in the
release listing, verifies its SHA-256 against that listing, and unpacks it to
`%LOCALAPPDATA%\Programs\Graffitty`. It also adds **Open in Graffitty** to File
Explorer. There is no separate installer program to download.

## Graphics startup on Windows and Linux

Open Graffitty normally. If a graphics driver crashes during startup, the
installed launcher automatically tries the next renderer and remembers the
one that works. A notice names the renderer in use. If effects are missing,
update your graphics driver and reopen Graffitty. A driver or Graffitty
version change triggers a fresh check.

## Update

Run `gft self update` to install the latest published build. It checks the
release listing against the SHA-256 recorded at installation. Republishing an
archive under the same tag triggers an update. Use `gft self update --version
<tag>` to select a specific release.

Rerun the install command to download, verify and reinstall the published
archive, even when its checksum matches. To skip an identical build on
Linux or macOS, pass the option to the shell that runs the installer.

```sh
curl -fsSL https://graffitty.com/install.sh | GRAFFITTY_INSTALL_SKIP_IF_EXISTS=1 sh
```

On Windows, set `$env:GRAFFITTY_INSTALL_SKIP_IF_EXISTS = '1'` in PowerShell
before running the install command. On all three platforms, a missing checksum
triggers a verified install.

During replacement, you can leave Graffitty open.

- Terminals and the programs in them keep running.
- Open windows close and reopen on the new version, showing the same session.
- A [checkpoint](../everyday-use/checkpoints.md) is saved before the switch.

Terminals that were already open stay on the previous version's terminal
process until you close them; new terminals use the new version.

## Android

1. Download the APK from [Releases](https://github.com/graffitty/graffitty/releases).
2. Install it on your device.
3. Follow [Remote access](../remote-access/index.md) to connect to a computer running Graffitty.

## iOS

There is no prebuilt iOS download yet. Building it yourself is covered in the
[iOS development guide](../developers/build-and-run/ios.md).

## Next step

[Open your first workspace →](getting-started.md)
