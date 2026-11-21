param([switch]$Debug)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'prepare-windows-video.ps1')
$manifest = Join-Path $root 'apps/cli/Cargo.toml'
$argsList = @('build', '--locked', '--manifest-path', $manifest)
$profile = 'debug'
if (-not $Debug) { $argsList += '--release'; $profile = 'release' }
& cargo @argsList
if ($LASTEXITCODE -ne 0) { throw 'Graffitty CLI build failed' }
$metadata = (& cargo metadata --no-deps --format-version 1 --manifest-path $manifest | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed' }
$binary = Join-Path $metadata.target_directory "$profile/gft.exe"
$destination = Join-Path $root 'dist/bin'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -LiteralPath $binary -Destination (Join-Path $destination 'gft.exe') -Force
# gft-gui is gft under another name, never a second copy of it. A link needs
# privileges on Windows; `gft gui` is the same launcher.
[IO.File]::WriteAllText((Join-Path $destination 'gft-gui.cmd'), "@`"%~dp0gft.exe`" gui %*`r`n", [Text.Encoding]::ASCII)
Remove-Item -LiteralPath (Join-Path $destination 'gft-gui.exe') -Force -ErrorAction SilentlyContinue
Write-Output 'Installed dist/bin/gft.exe and dist/bin/gft-gui.cmd'
