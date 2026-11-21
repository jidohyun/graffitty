# Run on Windows with pwsh -NoProfile -File packaging/windows/test_install.ps1
# (or powershell.exe). Downloads, gft, icacls, the Start menu shortcut, the
# Explorer menu and persistent PATH changes are mocked. Files are installed
# only under a temporary LOCALAPPDATA.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$source = Join-Path $PSScriptRoot '..\install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([ScriptBlock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert $failed $Message
}
function Write-Fixture([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Join-Path ([IO.Path]::GetTempPath()) ('graffitty-ps-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$originalLocal = $env:LOCALAPPDATA
$originalState = $env:XDG_STATE_HOME
$originalVersion = $env:GRAFFITTY_VERSION
$originalReleases = $env:GRAFFITTY_RELEASES
$originalSkip = $env:GRAFFITTY_INSTALL_SKIP_IF_EXISTS
$env:GRAFFITTY_RELEASES = $null
$originalCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
try {
    $env:LOCALAPPDATA = Join-Path $root 'user with spaces'
    $env:XDG_STATE_HOME = Join-Path $root 'state'
    $destination = Join-Path $env:LOCALAPPDATA 'Programs\Graffitty'
    $record = Join-Path $env:XDG_STATE_HOME 'graffitty\server.update.json'

    # Two release archives: a complete one and one without gft.
    $complete = Join-Path $root 'complete'
    foreach ($relative in @('Graffitty.exe', 'GraffittyRuntime.exe', 'tools\gft.exe', 'tools\gft-gui.cmd', 'chromium-windows\libcef.dll', 'install-context-menu.ps1')) {
        Write-Fixture (Join-Path $complete "Graffitty\$relative") 'new'
    }
    $completeZip = Join-Path $root 'complete.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($complete, $completeZip)
    Write-Fixture (Join-Path $complete 'Graffitty\Graffitty.exe') 'republished'
    $republishedZip = Join-Path $root 'republished.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($complete, $republishedZip)
    $partial = Join-Path $root 'partial'
    Write-Fixture (Join-Path $partial 'Graffitty\Graffitty.exe') 'new'
    Write-Fixture (Join-Path $partial 'Graffitty\GraffittyRuntime.exe') 'new'
    $partialZip = Join-Path $root 'partial.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($partial, $partialZip)

    # The real Explorer registration runs the bundled script as text, with the
    # installed executable.
    $menu = Join-Path $root 'menu'
    Write-Fixture (Join-Path $menu 'install-context-menu.ps1') 'param([string]$Executable) [IO.File]::WriteAllText((Join-Path (Split-Path $Executable) ''registered.txt''), $Executable)'
    Register-GraffittyContextMenu $menu
    Assert ([IO.File]::ReadAllText((Join-Path $menu 'registered.txt')) -eq (Join-Path $menu 'Graffitty.exe')) 'Explorer registration did not receive the executable'
    Register-GraffittyContextMenu (Join-Path $root 'no-such-bundle')

    # Every language's description decodes; unknown languages read English.
    foreach ($culture in @('en-US', 'fr-FR', 'pt-BR', 'es-ES', 'it-IT', 'ko-KR', 'ja-JP', 'de-DE', 'nb-NO', 'nn-NO', 'sv-SE', 'da-DK', 'fi-FI')) {
        [Threading.Thread]::CurrentThread.CurrentUICulture = $culture
        Assert ((Get-GraffittyDescription).Contains('Chromium')) "No shortcut description for $culture"
    }
    [Threading.Thread]::CurrentThread.CurrentUICulture = 'ko-KR'
    Assert ((Get-GraffittyDescription)[0] -eq [char]0xD130) 'Korean description is not decoded as UTF-8'
    [Threading.Thread]::CurrentThread.CurrentUICulture = 'fi-FI'
    Assert ((Get-GraffittyDescription).StartsWith('Terminals and')) 'Unknown language does not fall back to English'
    [Threading.Thread]::CurrentThread.CurrentUICulture = $originalCulture

    $script:mode = 'ok'
    $script:calls = @()
    $script:integrated = @()
    $script:tempDirectories = @()
    $script:tempFiles = @()
    $script:webRequests = 0
    $script:archiveRequests = 0
    $archiveAddress = 'https://storage.example/builds/win-1.2.3-build7.bin'
    $script:prepareCode = 0
    $script:parks = $false
    function Get-GraffittyPlatform { }
    # Exercise the Invoke-WebRequest fallback, which the mock below replaces.
    function Get-GraffittyCurl { return $null }
    # The release listing is on the site; this release's archives are stored elsewhere.
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
        $script:webRequests += 1
        # latest.txt is fetched to a file directly in the temporary directory;
        # everything else goes into the install's own temporary folder.
        if ((Split-Path (Split-Path $OutFile) -Leaf) -like 'graffitty-install-*') {
            $script:tempDirectories += Split-Path $OutFile
        } else {
            $script:tempFiles += $OutFile
        }
        if ($script:mode -eq 'network-failure') { throw 'Download failed' }
        $payload = switch ($script:mode) {
            'missing-payload' { $partialZip }
            'republished' { $republishedZip }
            default { $completeZip }
        }
        if ($Uri -eq 'https://graffitty.com/releases/latest.txt') {
            [IO.File]::WriteAllText($OutFile, "v1.2.3`r`n")
        } elseif ($Uri -eq 'https://graffitty.com/releases/v1.2.3.txt') {
            # The archive is stored on another host under another name: only
            # the line's address says where. Other platforms share the file,
            # and the lines end in CRLF.
            $hash = (Get-FileHash $payload -Algorithm SHA256).Hash
            $line = "$hash  graffitty-windows-x64.zip  $archiveAddress"
            switch ($script:mode) {
                'bad-hash' { $line = ('0' * 64) + "  graffitty-windows-x64.zip  $archiveAddress" }
                'missing-hash' { $line = "$hash  unrelated.zip  $archiveAddress" }
                'duplicate-hash' { $line += "`r`n$line" }
                'http-address' { $line = "$hash  graffitty-windows-x64.zip  http://storage.example/builds/win-1.2.3-build7.bin" }
            }
            $others = @(
                (('a' * 64) + '  graffitty-macos-arm64.tar.gz  https://storage.example/builds/mac-1.2.3.bin'),
                (('b' * 64) + '  graffitty-linux-x86_64.tar.gz  linux/x86_64.tar.gz')
            )
            [IO.File]::WriteAllText($OutFile, (@($others[0], $line, $others[1]) -join "`r`n") + "`r`n")
        } else {
            Assert ($Uri -eq $archiveAddress) "Wrong archive URL: $Uri"
            $script:archiveRequests += 1
            Copy-Item -LiteralPath $payload -Destination $OutFile
        }
    }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $WindowStyle)
        Assert ($Wait -and $PassThru) 'Tools must be awaited'
        $call = (Split-Path $FilePath -Leaf) + ' ' + ($ArgumentList -join ' ')
        $script:calls += $call
        if ($call -eq 'gft.exe internal update prepare') {
            if ($script:prepareCode -eq 0 -and $script:parks) { Write-Fixture $record '{}' }
            return @{ ExitCode = $script:prepareCode }
        }
        if ($call -eq 'gft.exe internal update finish') {
            Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
            return @{ ExitCode = 0 }
        }
        Assert ($call.StartsWith('icacls.exe ')) "Unexpected program: $call"
        Assert ($ArgumentList -contains ('"' + (Join-Path $destination 'chromium-windows') + '"')) 'Sandbox path must be quoted'
        return @{ ExitCode = $(if ($script:mode -eq 'icacls-failure') { 5 } else { 0 }) }
    }
    function Add-GraffittyPath {
        param($Tools)
        Assert ($Tools -eq (Join-Path $destination 'tools')) 'Wrong PATH entry'
        $script:integrated += 'path'
    }
    function New-GraffittyShortcut {
        param($Executable)
        Assert ($Executable -eq (Join-Path $destination 'Graffitty.exe')) 'Wrong shortcut target'
        $script:integrated += 'shortcut'
    }
    function Register-GraffittyContextMenu {
        param($Destination)
        $script:integrated += 'menu'
    }
    # What the user owns, outside the install directory: an upgrade never changes it.
    $userFiles = @(
        (Join-Path $root 'config\graffitty\client.toml'),
        (Join-Path $root 'config\graffitty\server.toml'),
        (Join-Path $root 'data\graffitty\worlds\mine.pck')
    )
    function Install-Previous {
        # The last five are from an older version: the new archive ships none of them.
        foreach ($relative in @('Graffitty.exe', 'tools\gft.exe', 'tools\gft-gui.cmd', 'tools\gft-gui.exe', 'Graffitty.pck', 'tools\gft.exe.old-1',
                'filetree\plugins\dropped\init.lua', 'shell-integration\old.ps1', 'chromium-windows\VkLayer_khronos_validation.dll',
                'unins000.exe', 'unins000.dat')) {
            Write-Fixture (Join-Path $destination $relative) 'old'
        }
        foreach ($file in $userFiles + @((Join-Path $env:LOCALAPPDATA 'graffitty\server.json'), (Join-Path $env:LOCALAPPDATA 'graffitty\auth.json'))) {
            Write-Fixture $file 'mine'
        }
    }
    function Assert-UserFilesKept {
        foreach ($file in $userFiles + @((Join-Path $env:LOCALAPPDATA 'graffitty\server.json'), (Join-Path $env:LOCALAPPDATA 'graffitty\auth.json'))) {
            Assert ((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -eq 'mine') "The upgrade changed the user's $file"
        }
    }
    function Read-Installed([string]$Relative) {
        $file = Join-Path $destination $Relative
        if (Test-Path -LiteralPath $file) { return [IO.File]::ReadAllText($file) }
        return $null
    }

    Assert ((Get-GraffittyReleaseTag '1.2.3' 'https://graffitty.com/releases') -eq 'v1.2.3') 'Version normalization failed'
    Assert ((Get-GraffittyReleaseTag 'latest' 'https://graffitty.com/releases') -eq 'v1.2.3') 'Latest release failed'
    Assert ((Get-GraffittyReleaseTag 'v1.2.3-rc.1' 'https://graffitty.com/releases') -eq 'v1.2.3-rc.1') 'Prerelease failed'
    Expect-Failure { Get-GraffittyReleaseTag '../bad' 'https://graffitty.com/releases' } 'Unsafe tag accepted'
    $tools = 'C:\User With Spaces\Programs\Graffitty\tools'
    Assert ((Get-GraffittyUpdatedPath '' $tools) -eq $tools) 'Empty PATH failed'
    Assert ((Get-GraffittyUpdatedPath 'C:\Other' $tools) -eq ('C:\Other;' + $tools)) 'Existing PATH lost'
    Assert ((Get-GraffittyUpdatedPath ($tools.ToUpper() + '\;C:\Other') $tools) -eq ($tools.ToUpper() + '\;C:\Other')) 'Duplicate PATH entry added'

    # A release listing in a local directory; the address is relative to it
    # and the stored file has another name than the archive.
    $listing = Join-Path $root 'listing'
    $completeHash = (Get-FileHash $completeZip -Algorithm SHA256).Hash
    Write-Fixture (Join-Path $listing 'latest.txt') "v1.2.3`r`n"
    Write-Fixture (Join-Path $listing 'v1.2.3.txt') "$completeHash  graffitty-windows-x64.zip  files/win.bin`n"
    New-Item -ItemType Directory -Path (Join-Path $listing 'files') -Force | Out-Null
    Copy-Item -LiteralPath $completeZip -Destination (Join-Path $listing 'files\win.bin')

    # One line per archive: checksum, name, address.
    $lines = Join-Path $root 'lines.txt'
    $mac = ('a' * 64) + '  graffitty-macos-arm64.tar.gz  https://storage.example/mac.bin'
    [IO.File]::WriteAllText($lines, "$mac`r`n$completeHash  graffitty-windows-x64.zip  https://storage.example/win.bin`r`n")
    $entry = Get-GraffittyReleaseEntry $lines 'graffitty-windows-x64.zip' 'https://graffitty.com/releases'
    Assert ($entry.Hash -eq $completeHash -and $entry.Address -eq 'https://storage.example/win.bin') 'Another platform or CRLF confused the listing'
    [IO.File]::WriteAllText($lines, "$completeHash  graffitty-windows-x64.zip  files/win.bin`n")
    Assert ((Get-GraffittyReleaseEntry $lines 'graffitty-windows-x64.zip' 'https://graffitty.com/releases').Address -eq 'https://graffitty.com/releases/files/win.bin') 'A relative address was not resolved against the listing'
    [IO.File]::WriteAllText($lines, "$completeHash  graffitty-windows-x64.zip  C:\Releases\win.bin`n")
    Assert ((Get-GraffittyReleaseEntry $lines 'graffitty-windows-x64.zip' 'https://graffitty.com/releases').Address -eq 'C:\Releases\win.bin') 'An absolute path was changed'
    [IO.File]::WriteAllText($lines, "$completeHash  graffitty-windows-x64.zip  http://storage.example/win.bin`n")
    Expect-Failure { Get-GraffittyReleaseEntry $lines 'graffitty-windows-x64.zip' 'https://graffitty.com/releases' } 'An http address was accepted'
    [IO.File]::WriteAllText($lines, "$mac`n")
    Expect-Failure { Get-GraffittyReleaseEntry $lines 'graffitty-windows-x64.zip' 'https://graffitty.com/releases' } 'A listing without this platform was accepted'

    $cases = @('fresh', 'reinstall', 'bad-hash', 'missing-hash', 'duplicate-hash', 'network-failure', 'missing-payload',
        'upgrade-running', 'upgrade-idle', 'old-gft', 'stale-held', 'prepare-failure', 'locked', 'icacls-failure',
        'local-listing', 'relative-listing', 'http-listing', 'missing-tag', 'http-address')
    foreach ($case in $cases) {
        $script:mode = $case
        $script:calls = @()
        $script:integrated = @()
        $script:prepareCode = 0
        $script:parks = $false
        Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $env:XDG_STATE_HOME -Recurse -Force -ErrorAction SilentlyContinue
        $env:GRAFFITTY_VERSION = '1.2.3'
        $env:GRAFFITTY_INSTALL_SKIP_IF_EXISTS = $null
        $env:GRAFFITTY_RELEASES = $null
        $script:webRequests = 0
        $script:archiveRequests = 0
        $held = $null
        try {
            switch ($case) {
                'fresh' {
                    Install-Graffitty
                    Assert ((Read-Installed 'tools\gft.exe') -eq 'new') 'Fresh install copied nothing'
                    Assert (($script:calls -join '|') -match '^icacls\.exe ') 'A fresh install must only configure the sandbox'
                    Assert (($script:integrated -join ',') -eq 'shortcut,menu,path') 'Fresh install did not integrate'
                    Assert ($script:archiveRequests -eq 1) 'The archive was not fetched from the address in the listing'
                    $shipped = @([IO.Directory]::GetFiles((Join-Path $complete 'Graffitty'), '*', 'AllDirectories')).Count
                    Assert ((Read-Installed '.archive-sha256') -eq $completeHash) 'The receipt must identify the verified archive'
                    Assert (@([IO.Directory]::GetFiles($destination, '*', 'AllDirectories')).Count -eq ($shipped + 1)) 'Unexpected files beside the payload and its receipt'
                }
                'reinstall' {
                    Install-Graffitty
                    Write-Fixture (Join-Path $destination 'Graffitty.exe') 'locally modified'
                    Install-Graffitty
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'new') 'A default reinstall did not restore the published executable'
                    Assert ($script:archiveRequests -eq 2) 'A default reinstall did not fetch the archive again'
                    $script:calls = @()
                    $script:integrated = @()
                    $env:GRAFFITTY_INSTALL_SKIP_IF_EXISTS = '1'
                    Install-Graffitty
                    Assert ($script:archiveRequests -eq 2 -and $script:calls.Count -eq 0 -and $script:integrated.Count -eq 0) 'An identical archive was not skipped'
                    # An earlier installer may have exited before resuming the session.
                    Write-Fixture $record '{}'
                    Install-Graffitty
                    Assert ($script:calls[-1] -eq 'gft.exe internal update finish') 'A matching receipt stranded a parked session'
                    $script:calls = @()
                    $script:mode = 'republished'
                    $script:parks = $true
                    Install-Graffitty
                    Assert ($script:archiveRequests -eq 4 -and (Read-Installed 'Graffitty.exe') -eq 'republished') 'The new build under the same tag was skipped'
                    Assert ((Read-Installed '.archive-sha256') -eq (Get-FileHash $republishedZip -Algorithm SHA256).Hash) 'The receipt was not updated'
                    Assert ($script:calls[0] -eq 'gft.exe internal update prepare' -and $script:calls[-1] -eq 'gft.exe internal update finish') 'Republishing bypassed the running-session handoff'
                }
                'upgrade-running' {
                    Install-Previous
                    $script:parks = $true
                    Install-Graffitty
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'new' -and (Read-Installed 'tools\gft.exe') -eq 'new') 'Upgrade left old files'
                    Assert ($null -eq (Read-Installed 'Graffitty.pck')) 'The old external pack survived'
                    Assert ($null -eq (Read-Installed 'tools\gft-gui.exe')) 'The old gft-gui program survived beside the script'
                    Assert ($null -eq (Read-Installed 'tools\gft.exe.old-1')) 'A file moved aside earlier survived'
                    Assert ($null -eq (Read-Installed 'filetree\plugins\dropped\init.lua')) 'A plugin the new version dropped survived'
                    Assert (-not (Test-Path -LiteralPath (Join-Path $destination 'filetree'))) 'A directory emptied by the upgrade survived'
                    Assert (-not (Test-Path -LiteralPath (Join-Path $destination 'shell-integration'))) 'A directory the new version dropped survived'
                    Assert ($null -eq (Read-Installed 'chromium-windows\VkLayer_khronos_validation.dll')) 'A library the new version dropped survived'
                    Assert ((Read-Installed 'chromium-windows\libcef.dll') -eq 'new') 'A shipped library was removed with the stale ones'
                    Assert ((Read-Installed 'unins000.exe') -eq 'old' -and (Read-Installed 'unins000.dat') -eq 'old') 'The installer-made uninstaller was removed'
                    Assert-UserFilesKept
                    Assert ($script:calls[0] -eq 'gft.exe internal update prepare') 'Files changed before Graffitty was parked'
                    Assert ($script:calls[-1] -eq 'gft.exe internal update finish') 'A parked Graffitty was not resumed last'
                    Assert (@($script:calls | Where-Object { $_ -like '*finish' }).Count -eq 1) 'Resumed more than once'
                }
                'upgrade-idle' {
                    Install-Previous
                    Install-Graffitty
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'new') 'Upgrade left old files'
                    Assert (-not ($script:calls -contains 'gft.exe internal update finish')) 'Resumed a Graffitty that was not running'
                }
                'old-gft' {
                    Install-Previous
                    $script:prepareCode = 2
                    Install-Graffitty
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'new') 'An older gft blocked the upgrade'
                }
                'local-listing' {
                    # latest.txt, the checksums and the archive all come from a directory.
                    $env:GRAFFITTY_RELEASES = $listing
                    $env:GRAFFITTY_VERSION = $null
                    Install-Graffitty
                    Assert ((Read-Installed 'tools\gft.exe') -eq 'new') 'A local listing installed nothing'
                    Assert ($script:webRequests -eq 0) 'A local listing made a web request'
                }
                { $_ -in @('relative-listing', 'http-listing') } {
                    $env:GRAFFITTY_RELEASES = if ($case -eq 'relative-listing') { 'releases' } else { 'http://graffitty.com/releases' }
                    Expect-Failure { Install-Graffitty } "GRAFFITTY_RELEASES was accepted in $case"
                    Assert ($script:webRequests -eq 0) 'Something was downloaded from a refused listing'
                    Assert ($script:calls.Count -eq 0) 'A refused listing ran a program'
                    Assert (-not (Test-Path -LiteralPath $destination)) 'A refused listing was installed'
                }
                'http-address' {
                    Install-Previous
                    Expect-Failure { Install-Graffitty } 'An archive address that is not https was fetched'
                    Assert ($script:webRequests -eq 1 -and $script:archiveRequests -eq 0) 'More than the listing was requested for a refused address'
                    Assert ($script:calls.Count -eq 0) 'Graffitty was parked for a refused address'
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'old') 'Files changed for a refused address'
                }
                'missing-tag' {
                    Install-Previous
                    $env:GRAFFITTY_RELEASES = $listing
                    $env:GRAFFITTY_VERSION = '9.9.9'
                    Expect-Failure { Install-Graffitty } 'A release the listing does not have was installed'
                    Assert ($script:calls.Count -eq 0) 'Graffitty was parked for a release that does not exist'
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'old' -and (Read-Installed 'Graffitty.pck') -eq 'old') 'Files changed for a release that does not exist'
                }
                'stale-held' {
                    # A running program still holds a file the new version dropped.
                    Install-Previous
                    $held = [IO.File]::Open((Join-Path $destination 'shell-integration\old.ps1'), 'Open', 'Read', 'None')
                    Install-Graffitty
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'new') 'A stale file in use blocked the upgrade'
                    Assert (Test-Path -LiteralPath (Join-Path $destination 'shell-integration\old.ps1')) 'A stale file in use was removed'
                    Assert ($null -eq (Read-Installed 'filetree\plugins\dropped\init.lua')) 'The other stale files stayed because one was in use'
                    Assert-UserFilesKept
                }
                'prepare-failure' {
                    Install-Previous
                    $script:prepareCode = 1
                    Expect-Failure { Install-Graffitty } 'Installed over a Graffitty that could not be parked'
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'old' -and (Read-Installed 'Graffitty.pck') -eq 'old') 'Files changed after a failed hand-over'
                    Assert ((Read-Installed 'filetree\plugins\dropped\init.lua') -eq 'old') 'Stale files were removed after a failed hand-over'
                    Assert ($script:calls.Count -eq 1) 'Ran more than the failed hand-over'
                }
                'locked' {
                    Install-Previous
                    $script:parks = $true
                    $held = [IO.File]::Open((Join-Path $destination 'tools\gft-gui.cmd'), 'Open', 'Read', 'None')
                    Expect-Failure { Install-Graffitty } 'Installed over a file in use'
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'old' -and (Read-Installed 'tools\gft.exe') -eq 'old') 'Some files were replaced before the file in use was found'
                    Assert ((Read-Installed 'Graffitty.pck') -eq 'old' -and (Read-Installed 'filetree\plugins\dropped\init.lua') -eq 'old') 'Stale files were removed although nothing was installed'
                    Assert ($script:calls[-1] -eq 'gft.exe internal update finish') 'A parked Graffitty was not resumed after the failure'
                }
                'icacls-failure' {
                    Install-Previous
                    $script:parks = $true
                    Write-Fixture (Join-Path $destination '.archive-sha256') ('f' * 64)
                    Expect-Failure { Install-Graffitty } 'A sandbox failure was reported as success'
                    Assert ($null -eq (Read-Installed '.archive-sha256')) 'An incomplete install left a receipt'
                    Assert ($script:calls[-1] -eq 'gft.exe internal update finish') 'A parked Graffitty was not resumed after the failure'
                }
                'missing-payload' {
                    Install-Previous
                    Expect-Failure { Install-Graffitty } 'An incomplete archive was installed'
                    Assert ($script:calls.Count -eq 0) 'Graffitty was parked for an archive that cannot be installed'
                    Assert ((Read-Installed 'Graffitty.exe') -eq 'old') 'An incomplete archive replaced files'
                }
                default {
                    Expect-Failure { Install-Graffitty } "Case $case unexpectedly succeeded"
                    Assert ($script:calls.Count -eq 0) 'An unverified download ran a program'
                    Assert (-not (Test-Path -LiteralPath $destination)) 'An unverified download was installed'
                }
            }
        } finally {
            if ($held) { $held.Dispose() }
        }
        if ($case -notin @('fresh', 'reinstall', 'upgrade-running', 'upgrade-idle', 'old-gft', 'stale-held', 'local-listing')) {
            Assert ($script:integrated.Count -eq 0) "PATH, shortcut or menu changed after failure in $case"
        }
        Assert (-not (Test-Path -LiteralPath $record)) "A parked record was left behind in $case"
        foreach ($directory in $script:tempDirectories + $script:tempFiles) {
            Assert (-not (Test-Path -LiteralPath $directory)) 'Temporary download was not cleaned up'
        }
        $programs = Join-Path $env:LOCALAPPDATA 'Programs'
        if (Test-Path -LiteralPath $programs) {
            Assert (@(Get-ChildItem -LiteralPath $programs -Force -Filter '.graffitty-install-*').Count -eq 0) "Unpacked files were left behind in $case"
        }
        Write-Host "PASS: $case"
    }
    Write-Host 'PASS: release tags, PATH preservation, descriptions, Explorer registration, script parsing'
} finally {
    [Threading.Thread]::CurrentThread.CurrentUICulture = $originalCulture
    $env:LOCALAPPDATA = $originalLocal
    $env:XDG_STATE_HOME = $originalState
    $env:GRAFFITTY_VERSION = $originalVersion
    $env:GRAFFITTY_RELEASES = $originalReleases
    $env:GRAFFITTY_INSTALL_SKIP_IF_EXISTS = $originalSkip
    Remove-Item -LiteralPath $root -Recurse -Force
}
