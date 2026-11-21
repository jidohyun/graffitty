# CEF on Windows

Build the Windows x64 runtime from `fork/cef/windows/`. For an existing binary, use [cached artifacts](cef-artifacts.md).

## Prepare and build

Run from the repository root with Python, Git, MSVC, and a Windows SDK.
Choose a new directory without spaces.

### Fetch and verify the tools

```powershell
$cefWork = 'C:/cef-work'
New-Item -ItemType Directory $cefWork -ErrorAction Stop
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$cefWork/depot_tools"
$pins = Get-Content fork/cef/pins.json | ConvertFrom-Json
git -C "$cefWork/depot_tools" checkout --detach $pins.depot_tools
Invoke-WebRequest "https://raw.githubusercontent.com/chromiumembedded/cef/$($pins.cef)/tools/automate/automate-git.py" -OutFile "$cefWork/automate-git.py"
if ((Get-FileHash "$cefWork/automate-git.py" -Algorithm SHA256).Hash.ToLower() -ne $pins.automate_sha256) { throw 'automate-git checksum mismatch' }
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_UPDATE = '0'
Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
python "$cefWork/automate-git.py" --download-dir=$cefWork --depot-tools-dir="$cefWork/depot_tools" --branch=$($pins.branch) --checkout=$($pins.cef) --chromium-checkout=$($pins.chromium_ref) --x64-build --no-debug-build --no-build --no-depot-tools-update
```

### Apply and generate

```powershell
$cefSource = "$cefWork/chromium/src"
python fork/cef/windows/apply_windows.py "$cefSource/cef" --patch-dir fork/cef/windows
$env:GN_DEFINES = (Get-Content fork/cef/windows/args.gn) -join ' '
$env:PATH = "$cefWork/depot_tools;$env:PATH"
Push-Location "$cefSource/cef"
.\cef_create_projects.bat
Pop-Location
```

Check for `out/Release_GN_x64/build.ninja` under `$cefSource`.

### Compile

From the repository root, build the configured checkout:

   ```powershell
   python fork/cef/windows/build_fork.py --source-root C:/cef-work/chromium/src `
     --depot-tools C:/depot_tools --jobs 8
   ```

`--source-root` must contain `cef/` and `out/Release_GN_x64/build.ninja`.
The builder checks the pinned Chromium revision, applies the Windows patch, and
builds `libcef`, `bootstrap`, and `bootstrapc`.

- Use the Windows capture patch, not the macOS patch.
- Build scripts do not reset or update existing checkouts.
- Keep `PYTHONUTF8` unset on non-UTF-8 Windows hosts.
- On a 32 GiB machine, use 8–10 jobs; 24 jobs exhausted the page file.
- Detached Task Scheduler builds should use priority `4`. Its default background priority can cause excessive linker paging.

## Validate

Test **both Alloy and Chrome** in an interactive desktop session:

- `tests/chromium/chromium_native_backend_e2e.py`.
- CMake target `chromium_capture_test`.
- Use an SSD for runtime files and profiles to avoid startup timeouts.

Checks cover real GPU pixels, shared storage, tab order, popups, presentation, Inspect and shutdown.

## Recorded status

- Both backends passed standalone host checks on **2026-10-26** using the same rebuilt DLL.
- The full Godot application run was **not repeated**.
- Binary revisions, hashes and provenance are in `fork/cef/artifacts/windows-x64/`.

See [Windows Chromium integration](../internals/windows-chromium.md) for application checks.
