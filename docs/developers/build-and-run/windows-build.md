# Windows builds

## Requirements

- x64 Windows.
- MSVC C++ build tools and a Windows SDK.
- Rust 1.96.0 or later, Zig 0.17.1 on PATH, Godot 4.7.2.
- A normal, **non-elevated desktop terminal launched by Explorer** for GUI and live-agent tests.

SSH service launches do not reproduce desktop input or GPU behavior. A working terminal or agent badge alone does not verify Ctrl+C or graph delivery.

## Build and launch

From PowerShell in the repository root:

```powershell
rustup toolchain install 1.96.0
.\tools\build-windows.ps1
.\tools\build-cli.ps1
godot --editor --headless --path frontends/godot/project --import
godot --path frontends/godot/project res://scenes/terminal.tscn
```

For subsequent changes:

| Change | Command |
| --- | --- |
| CLI/server | `mise run core:build` |
| Extension and native dependencies | `mise run dev:build` |
| Build and launch | `mise run dev` |
| GDScript only | `mise run dev -- --reload` |

See [development launches](development-launches.md) for restart choices and [Windows Chromium](../internals/windows-chromium.md) for browser builds.

## Release archive

Requires matching Godot export templates and the Chromium runtime:

```powershell
mise run windows:archive
```

To pack an already prepared bundle:

```powershell
uv run packaging/windows/build_archive.py --bundle dist/windows
```

- Output: `dist/installers/graffitty-windows-x64.zip` and its `SHA256SUMS` line.
- `packaging/install.ps1` installs it to `%LOCALAPPDATA%\Programs\Graffitty`.
- Signing is not configured; the executables are unsigned.
- See [Windows packaging](packaging-windows.md) for checksums and publication.

`mise run windows:installer -- --version 0.1.0` still compiles an Inno Setup
installer from the same bundle (requires Inno Setup 6). Releases do not publish
it.

### Validate the exported app

```powershell
uv run tests/platform/windows/windows_packaged_startup.py --bundle dist/windows
```

Run on the logged-in desktop, or a scheduled task with **Interactive** logon. SSH service sessions are reported as blocked. Headless compilation does not verify the native window frame or Direct3D swap chain.

See [test isolation, runtime limits, and recordings](windows-testing.md).
