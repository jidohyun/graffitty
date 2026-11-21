param(
    [string]$Toolchain = '1.96.0',
    [ValidateSet('dev', 'release')][string]$BuildProfile = 'release'
)
# Requires MSVC build tools, a Windows SDK, and Zig 0.15.2 on PATH.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $root 'frontends/godot/extension/Cargo.toml'
$cargoArgs = @("+$Toolchain")
Push-Location $root
try {
    . (Join-Path $PSScriptRoot 'prepare-windows-video.ps1')
    & uv run tools/build_info.py
    if ($LASTEXITCODE -ne 0) { throw "Build version generation failed" }
    $metadata = (& cargo @cargoArgs metadata --format-version 1 --no-deps --manifest-path $manifest | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed' }

    # Let the pinned dependency build Ghostty with its own Zig recipe first.
    # Its Windows static-link directive incorrectly names ghostty-vt.lib,
    # which is the DLL import library.
    #
    # That even imports _DllMainCRTStartup, bypassing this extension's CRT
    # constructors and Godot class registration.
    $ghosttyOut = $null
    # Windows PowerShell 5 treats redirected native stderr as errors, including
    # Cargo's normal progress. Check the exit code explicitly instead.
    $ErrorActionPreference = 'Continue'
    & cargo @cargoArgs check --profile $BuildProfile --locked --manifest-path $manifest --package libghostty-vt-sys --message-format=json | ForEach-Object {
        $message = $_ | ConvertFrom-Json
        if ($message.reason -eq 'compiler-message') { Write-Host $message.message.rendered }
        if ($message.reason -eq 'build-script-executed' -and $message.package_id -match 'libghostty-vt-sys') {
            $ghosttyOut = $message.out_dir
        }
    }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or -not $ghosttyOut) { throw 'Ghostty native build failed' }
    $install = Join-Path $ghosttyOut 'ghostty-install'
    $lib = Join-Path $install 'lib'
    if (-not (Test-Path (Join-Path $lib 'ghostty-vt-static.lib'))) { throw 'Ghostty static archive missing' }

    # Cargo supports overriding a links package's build-script output. Keep
    # this machine-specific file in target, without modifying registry sources.
    $config = Join-Path $metadata.target_directory 'windows-ghostty-static.toml'
    $libValue = $lib.Replace('\', '/') | ConvertTo-Json -Compress
    $includeValue = (Join-Path $install 'include').Replace('\', '/') | ConvertTo-Json -Compress
    @"
[target.x86_64-pc-windows-msvc]
# Ghostty's Zig-built C++ objects use /MT. Keep our C++ and Rust CRT consistent.
rustflags = ["-C", "target-feature=+crt-static"]

[target.x86_64-pc-windows-msvc.ghostty-vt]
rustc-link-lib = ["static=ghostty-vt-static"]
rustc-link-search = [$libValue]
include = $includeValue
"@ | Set-Content -Encoding ASCII $config

    $dll = $null
    $ErrorActionPreference = 'Continue'
    & cargo @cargoArgs build --profile $BuildProfile --locked --config $config --manifest-path $manifest --message-format=json | ForEach-Object {
        $message = $_ | ConvertFrom-Json
        if ($message.reason -eq 'compiler-message') { Write-Host $message.message.rendered }
        if ($message.reason -eq 'compiler-artifact' -and $message.target.name -eq 'graffitty') {
            $dll = $message.filenames | Where-Object { $_ -like '*.dll' } | Select-Object -First 1
        }
    }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or -not $dll) { throw 'Graffitty Godot extension build failed' }
    $destination = Join-Path $root 'frontends/godot/project/addons/graffitty/bin'
    New-Item -ItemType Directory -Force $destination | Out-Null
    Copy-Item $dll (Join-Path $destination 'libgraffitty.windows.x86_64.dll') -Force
    Write-Output "Staged Graffitty Godot extension in $destination"
} finally {
    Pop-Location
}
