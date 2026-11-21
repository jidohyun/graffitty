# Graffitty Windows install script: https://graffitty.com/install.ps1
#
#   powershell -c "irm https://graffitty.com/install.ps1 | iex"
#
# Set GRAFFITTY_VERSION to a release tag (e.g. v0.1.0); default: latest.
# Rerunning installs the published archive, even for the same tag.
# Set GRAFFITTY_INSTALL_SKIP_IF_EXISTS=1 to skip a matching installed archive SHA-256.
# Set GRAFFITTY_RELEASES to where releases are listed: an https URL or a local
# directory; default: https://graffitty.com/releases. The layout there:
#   latest.txt     the latest release tag
#   <tag>.txt      one line per archive of that release:
#                    <sha256>  <name>  <address>
#                  <name> is what this script asks for
#                  (graffitty-windows-x64.zip). <address> is where that file
#                  is: an https URL, or a path relative to the listing.
#
# This is always the current install script, also when an older Graffitty runs
# it (gft self update), so it must upgrade from every earlier version.
#
# Keep the published command free of -ExecutionPolicy Bypass and -NoProfile:
# uBlock Origin's ClickFix filter blocks copying commands that contain them.
# iex runs this text without a script file, so the execution policy does not
# apply and Bypass is not needed.
#
# Keep all work inside one script block so an incomplete download cannot
# install.
& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 3.0

    function Get-GraffittyPlatform {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'This script installs on Windows. Use install.sh on Linux or macOS.'
        }
        if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
            throw 'PowerShell 5.1 or later is required.'
        }
        $arch = $env:PROCESSOR_ARCHITEW6432
        if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
        if ($arch -ne 'AMD64') {
            throw "No Graffitty build is available for $arch. This release requires x64 Windows."
        }
        if ([Environment]::OSVersion.Version -lt [Version]'10.0.17763') {
            throw 'Graffitty requires Windows 10 version 1809 or later.'
        }
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set.' }
    }

    function Get-GraffittyReleases {
        $releases = $env:GRAFFITTY_RELEASES
        if (-not $releases) { $releases = 'https://graffitty.com/releases' }
        $releases = $releases.TrimEnd('/', '\')
        if ($releases -notlike 'https://*' -and -not [IO.Path]::IsPathRooted($releases)) {
            throw "GRAFFITTY_RELEASES must be an https URL or an absolute directory, not '$releases'."
        }
        return $releases
    }

    # Copies $Source, an https URL or an absolute path, to $OutFile.
    # Windows 10 1803 and later ship curl.exe. Windows PowerShell's
    # Invoke-WebRequest redraws its progress bar for every chunk, which made a
    # release archive download about ten times slower than curl.
    function Get-GraffittyCurl {
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($curl) { return $curl.Source }
        return $null
    }

    function Save-GraffittyFile {
        param([string]$Source, [string]$OutFile, [switch]$Progress)
        if ($Source -like 'https://*') {
            $curl = Get-GraffittyCurl
            if ($curl) {
                # Give up on a stalled transfer, never on a slow one.
                $display = if ($Progress) { '-#' } else { '-sS' }
                & $curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 30 `
                    --speed-limit 1024 --speed-time 60 $display -o $OutFile $Source
                if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE): $Source" }
            } else {
                $previous = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $OutFile -TimeoutSec 60
                } finally {
                    $ProgressPreference = $previous
                }
            }
        } elseif ([IO.Path]::IsPathRooted($Source)) {
            [IO.File]::Copy($Source, $OutFile, $true)
        } else {
            throw "Cannot fetch '$Source': not an https URL or an absolute path."
        }
    }

    function Get-GraffittyFirstLine {
        param([string]$File)
        $lines = @([IO.File]::ReadAllLines($File))
        if ($lines.Count -eq 0) { return '' }
        return $lines[0].Trim()
    }

    function Get-GraffittyReleaseTag {
        param([string]$Requested, [string]$Releases)
        if (-not $Requested -or $Requested -eq 'latest') {
            $file = Join-Path ([IO.Path]::GetTempPath()) ('graffitty-latest-' + [Guid]::NewGuid().ToString('N'))
            try {
                Save-GraffittyFile "$Releases/latest.txt" $file
                $tag = Get-GraffittyFirstLine $file
            } finally {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        } else {
            $tag = $Requested
            if (-not $tag.StartsWith('v')) { $tag = 'v' + $tag }
        }
        if ($tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?$') {
            throw "Invalid Graffitty release tag: $tag"
        }
        return $tag
    }

    # The checksum and address of $Asset in a release's listing file: the one
    # line "<sha256>  <name>  <address>" whose name is $Asset.
    function Get-GraffittyReleaseEntry {
        param([string]$Listing, [string]$Asset, [string]$Releases)
        $entries = @(
            foreach ($line in [IO.File]::ReadAllLines($Listing)) {
                if ($line.Trim() -match '^([0-9a-fA-F]{64})\s+(\S+)\s+(\S+)$' -and $Matches[2] -ceq $Asset) {
                    @{ Hash = $Matches[1]; Address = $Matches[3] }
                }
            }
        )
        if ($entries.Count -ne 1) { throw "The release must list $Asset exactly once." }
        $entry = $entries[0]
        # Another scheme, such as http, is never fetched and never taken for a path.
        if ($entry.Address -like '*://*' -and $entry.Address -notlike 'https://*') {
            throw "The release lists $Asset at an address that is not https: $($entry.Address)"
        }
        if ($entry.Address -notlike 'https://*' -and -not [IO.Path]::IsPathRooted($entry.Address)) {
            $entry.Address = "$Releases/" + $entry.Address
        }
        return $entry
    }

    function Assert-GraffittyChecksum {
        param([string]$Expected, [string]$Asset, [string]$File)
        $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
        if ($actual -ne $Expected) { throw "Checksum mismatch for $Asset; refusing to install it." }
    }

    function Get-GraffittyUpdatedPath {
        param([AllowNull()][string]$Current, [string]$Tools)
        foreach ($entry in ($Current -split ';')) {
            if ([Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\') -ieq $Tools.TrimEnd('\')) {
                return $Current
            }
        }
        if ([string]::IsNullOrEmpty($Current)) { return $Tools }
        return $Current.TrimEnd(';') + ';' + $Tools
    }

    function Add-GraffittyPath {
        param([string]$Tools)
        $current = [Environment]::GetEnvironmentVariable('Path', 'User')
        $updated = Get-GraffittyUpdatedPath $current $Tools
        if ($updated -cne $current) {
            [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        }
        $env:Path = Get-GraffittyUpdatedPath $env:Path $Tools
    }

    # Runs a program without a window and returns its exit code. Calling a
    # console program directly would turn anything it writes to stderr into a
    # terminating error under Windows PowerShell 5.1.
    function Invoke-GraffittyTool {
        param([string]$File, [string[]]$Arguments)
        $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
        return $process.ExitCode
    }

    # The file `gft internal update prepare` leaves behind when it closed a
    # running Graffitty. It is in gft's state directory.
    function Get-GraffittyParkedRecord {
        $state = $env:XDG_STATE_HOME
        if (-not $state) { $state = $env:LOCALAPPDATA }
        return Join-Path $state 'graffitty\server.update.json'
    }

    function Expand-GraffittyArchive {
        param([string]$Archive, [string]$Staging)
        # Expand-Archive takes minutes on an archive of this size in 5.1.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Staging)
        $payload = Join-Path $Staging 'Graffitty'
        foreach ($relative in @('Graffitty.exe', 'GraffittyRuntime.exe', 'tools\gft.exe', 'tools\gft-gui.cmd')) {
            if (-not (Test-Path -LiteralPath (Join-Path $payload $relative) -PathType Leaf)) {
                throw "The downloaded archive holds no $relative."
            }
        }
        return $payload
    }

    # The first installed file that a running program still holds open, if any.
    # Windows cannot replace such a file, so this is checked before copying.
    function Find-GraffittyLockedFile {
        param([string]$Payload, [string]$Destination)
        foreach ($file in [IO.Directory]::GetFiles($Payload, '*', 'AllDirectories')) {
            $relative = $file.Substring($Payload.Length).TrimStart('\')
            $target = Join-Path $Destination $relative
            if (-not [IO.File]::Exists($target)) { continue }
            try {
                [IO.File]::Open($target, 'Open', 'ReadWrite', 'None').Dispose()
            } catch {
                return $relative
            }
        }
        return $null
    }

    function Copy-GraffittyPayload {
        param([string]$Payload, [string]$Destination)
        foreach ($file in [IO.Directory]::GetFiles($Payload, '*', 'AllDirectories')) {
            $target = Join-Path $Destination $file.Substring($Payload.Length).TrimStart('\')
            [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
            [IO.File]::Copy($file, $target, $true)
        }
        Remove-GraffittyStaleFiles $Payload $Destination
    }

    # Deletes what an earlier version installed and this one no longer ships:
    # an external pack that would shadow the embedded one, a gft-gui program
    # that would be found before the gft-gui script, plugins and libraries the
    # new version dropped, and files an earlier upgrade moved aside (*.old-*).
    #
    # Only the install directory is touched. Settings, sessions, passwords and
    # worlds live in other directories and are never read or changed here.
    # Kept: unins*, which the Windows app list of an installer-made copy still
    # points at. A file a running program holds stays until a later install.
    function Remove-GraffittyStaleFiles {
        param([string]$Payload, [string]$Destination)
        $root = $Destination.TrimEnd('\') + '\'
        foreach ($file in [IO.Directory]::GetFiles($Destination, '*', 'AllDirectories')) {
            $relative = $file.Substring($root.Length)
            if ([IO.File]::Exists((Join-Path $Payload $relative))) { continue }
            if ($relative -notmatch '\\' -and $relative -like 'unins*') { continue }
            try { [IO.File]::Delete($file) } catch { }
        }
        # Deepest first, so a directory emptied above goes with its parents.
        $directories = [IO.Directory]::GetDirectories($Destination, '*', 'AllDirectories') |
            Sort-Object -Property Length -Descending
        foreach ($directory in $directories) {
            if ([IO.Directory]::GetFileSystemEntries($directory).Length -eq 0) {
                try { [IO.Directory]::Delete($directory) } catch { }
            }
        }
    }

    # The Start menu shortcut's description in the app's languages: the
    # AppDescription messages of packaging/windows/graffitty.iss as base64 of
    # UTF-8. This file stays ASCII because Windows PowerShell 5.1 reads a
    # script file without a byte order mark in the system code page.
    function Get-GraffittyDescription {
        $descriptions = @{
            en = 'VGVybWluYWxzIGFuZCBDaHJvbWl1bSBpbiBvbmUgY29ubmVjdGVkIHdvcmtzcGFjZQ=='
            fr = 'VGVybWluYXV4IGV0IENocm9taXVtIGRhbnMgdW4gbcOqbWUgZXNwYWNlIGRlIHRyYXZhaWwgY29ubmVjdMOp'
            pt = 'VGVybWluYWlzIGUgQ2hyb21pdW0gZW0gdW0gc8OzIGVzcGHDp28gZGUgdHJhYmFsaG8gY29uZWN0YWRv'
            es = 'VGVybWluYWxlcyB5IENocm9taXVtIGVuIHVuIG1pc21vIGVzcGFjaW8gZGUgdHJhYmFqbyBjb25lY3RhZG8='
            it = 'VGVybWluYWxpIGUgQ2hyb21pdW0gaW4gdW4gdW5pY28gc3BhemlvIGRpIGxhdm9ybyBjb2xsZWdhdG8='
            ko = '7YSw66+464SQ6rO8IENocm9taXVt7J2EIO2VmOuCmOuhnCDsl7DqsrDtlZjripQg7J6R7JeFIOqzteqwhA=='
            ja = '44K/44O844Of44OK44Or44GoIENocm9taXVtIOOCkuOBpOOBquOBkOOBsuOBqOOBpOOBruODr+ODvOOCr+OCueODmuODvOOCuQ=='
            de = 'VGVybWluYWxzIHVuZCBDaHJvbWl1bSBpbiBlaW5lbSB2ZXJidW5kZW5lbiBBcmJlaXRzYmVyZWljaA=='
            nb = 'VGVybWluYWxlciBvZyBDaHJvbWl1bSBpIGV0dCBzYW1tZW5rb2JsZXQgYXJiZWlkc29tcsOlZGU='
            sv = 'VGVybWluYWxlciBvY2ggQ2hyb21pdW0gaSBlbiBzYW1tYW5rb3BwbGFkIGFyYmV0c3l0YQ=='
            da = 'VGVybWluYWxlciBvZyBDaHJvbWl1bSBpIMOpdCBmb3JidW5kZXQgYXJiZWpkc29tcsOlZGU='
        }
        $language = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        if ($language -in @('no', 'nn')) { $language = 'nb' }
        if (-not $descriptions.ContainsKey($language)) { $language = 'en' }
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($descriptions[$language]))
    }

    function New-GraffittyShortcut {
        param([string]$Executable)
        $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Graffitty.lnk'
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
        $link.TargetPath = $Executable
        $link.WorkingDirectory = $env:USERPROFILE
        $link.Description = Get-GraffittyDescription
        $link.Save()
    }

    # Adds Open in Graffitty to File Explorer with the script the bundle
    # ships. It is run as text, as this script is, so the execution policy
    # does not block it.
    function Register-GraffittyContextMenu {
        param([string]$Destination)
        $script = Join-Path $Destination 'install-context-menu.ps1'
        if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { return }
        $text = [IO.File]::ReadAllText($script)
        & ([ScriptBlock]::Create($text)) -Executable (Join-Path $Destination 'Graffitty.exe')
    }

    function Install-Graffitty {
        Get-GraffittyPlatform
        $releases = Get-GraffittyReleases
        $tag = Get-GraffittyReleaseTag $env:GRAFFITTY_VERSION $releases
        $asset = 'graffitty-windows-x64.zip'
        $destination = Join-Path $env:LOCALAPPDATA 'Programs\Graffitty'
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('graffitty-install-' + [Guid]::NewGuid().ToString('N'))
        # Unpack beside the destination: the same drive, and a short path.
        $staging = Join-Path (Split-Path $destination) ('.graffitty-install-' + [Guid]::NewGuid().ToString('N'))
        $gft = Join-Path $destination 'tools\gft.exe'
        $receipt = Join-Path $destination '.archive-sha256'
        $parked = $false
        $installLock = $null
        New-Item -ItemType Directory -Path $temporary | Out-Null
        try {
            $archive = Join-Path $temporary $asset
            $listing = Join-Path $temporary 'release.txt'
            # The release's line for this archive gives both its checksum and
            # its address, so the file may be stored anywhere, under any name.
            Save-GraffittyFile "$releases/$tag.txt" $listing
            $entry = Get-GraffittyReleaseEntry $listing $asset $releases
            # Serialize the receipt check, file copies and running-session handoff.
            $lockPath = Join-Path $env:LOCALAPPDATA '.graffitty-install.lock'
            [IO.Directory]::CreateDirectory($env:LOCALAPPDATA) | Out-Null
            $installLock = [IO.FileStream]::new([string]$lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, [int]4096, [IO.FileOptions]::DeleteOnClose)
            if ($env:GRAFFITTY_INSTALL_SKIP_IF_EXISTS -eq '1' -and
                [IO.File]::Exists($gft) -and [IO.File]::Exists((Join-Path $destination 'Graffitty.exe')) -and
                [IO.File]::Exists($receipt) -and [IO.File]::ReadAllText($receipt).Trim() -eq $entry.Hash -and
                -not [IO.File]::Exists((Get-GraffittyParkedRecord))) {
                Write-Host "Graffitty $tag is already installed (archive SHA-256 matches)."
                return
            }
            Write-Host "Downloading Graffitty $tag..."
            Save-GraffittyFile $entry.Address $archive -Progress
            Assert-GraffittyChecksum $entry.Hash $asset $archive
            Write-Host 'Unpacking...'
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            $payload = Expand-GraffittyArchive $archive $staging
            # Windows cannot replace the files of a running Graffitty. So the
            # installed gft first saves a checkpoint, closes the windows,
            # leaves the terminals running in their holder processes and moves
            # aside the files a holder still runs from.
            if (Test-Path -LiteralPath $gft -PathType Leaf) {
                $code = Invoke-GraffittyTool $gft @('internal', 'update', 'prepare')
                # 0 = done, 2 = this gft is too old to know the command (carry
                # on without it), anything else = failed.
                if ($code -eq 0) {
                    $parked = Test-Path -LiteralPath (Get-GraffittyParkedRecord) -PathType Leaf
                } elseif ($code -ne 2) {
                    throw 'Graffitty is running and could not hand over its terminals. Nothing was changed. Close Graffitty, then run this again.'
                }
            }
            $locked = Find-GraffittyLockedFile $payload $destination
            if ($locked) {
                throw "$locked is in use by a running program. Nothing was changed. Close Graffitty, then run this again."
            }
            Write-Host 'Installing Graffitty for the current user...'
            # An interrupted in-place copy must never advertise the old build.
            if ([IO.File]::Exists($receipt)) { [IO.File]::Delete($receipt) }
            Copy-GraffittyPayload $payload $destination
            # Chromium's least-privileged app containers need read and execute
            # access to the runtime. Unpacking an archive does not grant it.
            $chromium = Join-Path $destination 'chromium-windows'
            if (Test-Path -LiteralPath $chromium -PathType Container) {
                $code = Invoke-GraffittyTool (Join-Path $env:SystemRoot 'System32\icacls.exe') `
                    @(('"' + $chromium + '"'), '/grant', '"*S-1-15-2-2:(OI)(CI)(RX)"', '/T', '/Q')
                if ($code -ne 0) { throw 'Could not configure the Chromium sandbox runtime.' }
            }
            New-GraffittyShortcut (Join-Path $destination 'Graffitty.exe')
            Register-GraffittyContextMenu $destination
            Add-GraffittyPath (Join-Path $destination 'tools')
            [IO.File]::WriteAllText($receipt, $entry.Hash.ToLowerInvariant())
            Write-Host "Graffitty $tag is installed. Open Graffitty from the Start menu."
            Write-Host 'Open a new terminal to use gft and gft-gui.'
        } finally {
            # Also after a failure: if Graffitty was closed for the upgrade,
            # start the installed server, which takes over the running
            # terminals, and reopen the windows.
            try {
                if ($parked -and (Test-Path -LiteralPath $gft -PathType Leaf)) {
                    Invoke-GraffittyTool $gft @('internal', 'update', 'finish') | Out-Null
                }
            } finally {
                if ($installLock) { $installLock.Dispose() }
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        Install-Graffitty
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
    }
}
