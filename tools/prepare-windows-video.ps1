# Dot-source before Cargo so the CLI/server and desktop extension use the same
# pinned static codec libraries.
#
# A missing toolchain must fail the build, rather than quietly shipping a
# server that can only send PNG browser frames.
$videoRoot = Split-Path $PSScriptRoot -Parent
$msysRoot = if ($env:MSYS2_ROOT) { $env:MSYS2_ROOT } else { 'C:/msys64' }
$env:PKG_CONFIG = Join-Path $msysRoot 'mingw64/bin/pkg-config.exe'
if (-not (Test-Path $env:PKG_CONFIG)) {
    throw 'Install MSYS2 make, mingw-w64-x86_64-pkgconf and mingw-w64-x86_64-nasm; set MSYS2_ROOT if needed'
}
& uv run (Join-Path $videoRoot 'tools/build_chromium_video.py') --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Windows hardware video library build failed' }
$env:GRAFFITTY_VIDEO_REQUIRED = '1'
