$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'graffitty'
$bin = [IO.File]::ReadAllText((Join-Path $root 'server-path.txt')).Trim()
$server = Join-Path $bin 'gft.exe'
$state = Join-Path $root 'state'
[IO.Directory]::CreateDirectory($state) | Out-Null
$descriptor = Join-Path $state 'server.json'
function Get-ServerStatus {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $server
    $info.Arguments = 'server --connection "' + $descriptor + '" --status'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $text = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -eq 0) { return $text }
    return $null
}
$status = Get-ServerStatus
if ($status) { [Console]::WriteLine($status); exit 0 }
# WMI starts outside sshd's process tree. Explicit breakaway also avoids the
# provider job's lifetime: https://learn.microsoft.com/windows/win32/cimwin32prov/create-method-in-class-win32-process
$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{CreateFlags = [uint32]16777224; ShowWindow = [uint16]0}
$line = '"' + $server + '" server --listen 127.0.0.1:0 --connection "' + $descriptor + '"'
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $line; CurrentDirectory = $env:USERPROFILE; ProcessStartupInformation = $startup}
if ($created.ReturnValue -ne 0) { throw "Headless server startup failed (WMI $($created.ReturnValue))" }
for ($i = 0; $i -lt 100; $i++) {
    $status = Get-ServerStatus
    if ($status) { [Console]::WriteLine($status); exit 0 }
    Start-Sleep -Milliseconds 100
}
throw 'Headless server did not publish its connection descriptor'
