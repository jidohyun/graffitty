# Per-user Explorer integration for an extracted Windows bundle. No elevation.
[CmdletBinding()]
param(
    [string]$Executable = (Join-Path $PSScriptRoot 'Graffitty.exe'),
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
if (-not $Uninstall) {
    $Executable = (Resolve-Path -LiteralPath $Executable).Path
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw 'Executable must be the exported Graffitty.exe'
    }
}
foreach ($target in @('Directory', 'Directory\Background', 'Drive')) {
    $key = "Software\Classes\$target\shell\Graffitty"
    if ($Uninstall) {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($key, $false)
        continue
    }
    $selection = if ($target -eq 'Directory\Background') { '%V' } else { '%1' }
    $verb = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($key)
    try {
        $verb.SetValue('', 'Open in Graffitty')
        $verb.SetValue('Icon', ('"{0}",0' -f $Executable))
        $command = $verb.CreateSubKey('command')
        try {
            # Protect a drive root's trailing backslash from Windows argv parsing.
            $command.SetValue('', ('"{0}" -- --cwd "{1}\."' -f $Executable, $selection))
        } finally { $command.Dispose() }
    } finally { $verb.Dispose() }
}
