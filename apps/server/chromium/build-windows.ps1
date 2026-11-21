param(
    [Parameter(Mandatory=$true)][string]$CefRoot,
    [string]$CMake = 'cmake',
    [string]$Generator = 'Visual Studio 17 2022'
)
$ErrorActionPreference = 'Stop'
$CefRoot = (Resolve-Path -LiteralPath $CefRoot).Path.Replace('\', '/')
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$build = Join-Path $root 'target/chromium-windows'
$destination = Join-Path $root 'dist/chromium-windows'
$archive = Join-Path $root 'fork/cef/artifacts/windows-x64/cef-windows-x64-runtime.zip'
if (-not (Test-Path $archive)) { throw 'Missing Windows CEF asset; see docs/developers/internals/windows-chromium.md' }
$provenance = Get-Content (Join-Path (Split-Path $archive) 'provenance.json') -Raw | ConvertFrom-Json
$sourceInputs = @('pins.json', 'graffitty_history.cc', 'graffitty_history.h', 'native_tabs.cc', 'native_tabs.h', 'native_tabs.patch',
    'session_lifetime.h', 'session_lifetime.patch', 'windows/apply_windows.py',
    'windows/build_fork.py', 'windows/args.gn', 'windows/chrome_gpu_capture.cc',
    'windows/chrome_gpu_capture.h')
if ($provenance.target -ne 'windows-x64' -or
    @(Compare-Object $sourceInputs @($provenance.inputs_sha256.PSObject.Properties.Name)).Count -ne 0) {
    throw 'Unexpected Windows CEF provenance; rebuild and package the current fork.'
}
foreach ($name in $sourceInputs) {
    $sourceHash = (Get-FileHash -Algorithm SHA256 (Join-Path "$root/fork/cef" $name)).Hash
    if ($sourceHash -ne $provenance.inputs_sha256.PSObject.Properties[$name].Value) {
        throw "Cached CEF does not match $name; rebuild and package the current fork."
    }
}
$archiveHash = (Get-FileHash -Algorithm SHA256 $archive).Hash
if ($archiveHash -ne $provenance.archive_sha256) { throw 'CEF archive does not match its provenance.' }
$unpack = Join-Path $build 'runtime'
$archiveStamp = Join-Path $build 'runtime-archive.sha256'
if (-not (Test-Path "$unpack/Release/libcef.dll") -or
    -not (Test-Path $archiveStamp) -or
    ([string](Get-Content $archiveStamp -Raw)).Trim() -ne $archiveHash) {
    # A DVC update must replace the extracted runtime, including removed files.
    if (Test-Path $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $unpack
    Set-Content -LiteralPath $archiveStamp -Value $archiveHash
}
# Verify every runtime byte against the preserved source-build manifest.
$checks = Join-Path $root 'fork/cef/artifacts/windows-x64/SHA256SUMS-runtime-files'
foreach ($line in Get-Content $checks) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        $expected = $Matches[1]; $relative = $Matches[2]
        $file = Join-Path "$unpack/Release" $relative
        if ((Get-FileHash -Algorithm SHA256 $file).Hash -ne $expected) { throw "CEF hash mismatch: $relative" }
    }
}
& $CMake -S $PSScriptRoot -B $build -G $Generator -A x64 "-DCEF_ROOT=$CefRoot" "-DCEF_BOOTSTRAP_EXE=$unpack/Release/bootstrap.exe"
if ($LASTEXITCODE -ne 0) { throw 'Chromium CMake configuration failed' }
& $CMake --build $build --config Release --parallel 8
if ($LASTEXITCODE -ne 0) { throw 'Chromium host build failed' }
# graffitty_chromium.exe turns GPU capture on with a switch libcef.dll was
# compiled to recognise, matched literally. A runtime built with other names
# would leave capture silently off, so stop before replacing the installed host.
$libcef = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes("$unpack/Release/libcef.dll"))
if (-not $libcef.Contains('graffitty-chrome-gpu-capture') -or -not $libcef.Contains('graffitty-native-tabs')) {
    throw 'The bundled libcef.dll is missing GPU capture or native tab control; rebuild it from fork/cef before this host.'
}
New-Item -ItemType Directory -Force $destination | Out-Null
$obsoleteBridge = Join-Path $destination 'tab_bridge.js'
if (Test-Path -LiteralPath $obsoleteBridge) { Remove-Item -LiteralPath $obsoleteBridge -Force }
# The Vulkan validation layer is a 20 MB debugging aid of the CEF build; the
# host never turns validation on, so it is not part of the runtime.
Get-ChildItem -LiteralPath $destination -Filter 'VkLayer_khronos_validation.*' | Remove-Item -Force
Get-ChildItem "$unpack/Release" | Where-Object { $_.Name -ne 'bootstrap.exe' -and $_.Name -notlike 'VkLayer_khronos_validation.*' } | Copy-Item -Destination $destination -Recurse -Force
Copy-Item "$build/Release/graffitty_chromium.exe" $destination -Force
Copy-Item "$build/Release/graffitty_chromium.dll" $destination -Force
# Sandboxed network/renderer processes need read/execute access after staging.
& icacls $destination /grant '*S-1-15-2-2:(OI)(CI)(RX)' /T /Q
if ($LASTEXITCODE -ne 0) { throw 'Chromium sandbox ACL setup failed' }
$info = Join-Path $destination 'build-info.json'
$process = Start-Process -FilePath (Join-Path $destination 'graffitty_chromium.exe') -ArgumentList @('--write-build-info', "`"$info`"") -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0) { throw 'Chromium version generation failed' }
Write-Output "Installed $destination/graffitty_chromium.exe"
