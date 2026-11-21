<#
.SYNOPSIS
Guided physical-input checks. Run inside the Godot terminal, once per shell.
.EXAMPLE
& .\tests\platform\windows\windows_manual_input.ps1 -Stage Start -Evidence .\.cache\windows-e2e\manual-ps51

Set Windows Settings > System > Display > Scale to 150% first. Keep a screen
recording of the complete sequence. Use a fresh evidence directory for each
PowerShell version. These checks require actual keyboard and mouse input.
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Start', 'Interrupt', 'Copy', 'Wheel', 'Review')][string]$Stage,
    [Parameter(Mandatory=$true)][string]$Evidence
)
$ErrorActionPreference = 'Stop'
$recordPath = Join-Path $Evidence 'physical-input.json'
$marker = 'GRAFFITTY_PHYSICAL_COPY_4729'
if ($Stage -eq 'Start') {
    if (Test-Path -LiteralPath $Evidence) { throw 'Use a fresh evidence directory.' }
    New-Item -ItemType Directory -Path $Evidence | Out-Null
    $record = [ordered]@{
        status = 'incomplete'; shell_pid = $PID
        shell_version = $PSVersionTable.PSVersion.ToString()
        executable = (Get-Process -Id $PID).Path
        started = (Get-Date).ToString('o')
        interrupt = $false; copy = $false; wheel = $false
        physical_input_attested = $false; scale_150_attested = $false
    }
} else {
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    if ($record.shell_pid -ne $PID) { throw 'The original shell did not survive, or this is another pane.' }
}
switch ($Stage) {
    Start {
        Write-Host 'Start a continuous screen recording. Clear any text selection.'
        Write-Host 'Run the following loop, press physical Ctrl+C, then run this script with -Stage Interrupt and the same -Evidence:'
        Write-Host 'while ($true) { Write-Host "PHYSICAL_INTERRUPT_RUNNING"; Start-Sleep -Seconds 1 }'
    }
    Interrupt {
        if ((Read-Host 'Did physical Ctrl+C stop the loop and return to this prompt? Type YES') -cne 'YES') { throw 'Interrupt remains unverified.' }
        $record.interrupt = $true
        Write-Host 'Run the following command. Select ONLY the marker on its output line with the mouse, then press physical Ctrl+Shift+C:'
        Write-Host "Write-Output '$marker'"
        Write-Host 'Then run this script with -Stage Copy.'
    }
    Copy {
        if (-not $record.interrupt) { throw 'Complete Interrupt first.' }
        if ((Get-Clipboard -Raw).TrimEnd("`r", "`n") -cne $marker) { throw 'Clipboard does not exactly match the selected marker. No clipboard content was saved.' }
        $record.copy = $true
        Write-Host 'Selection copy matched and the original shell is alive.'
        Write-Host 'Run this script with -Stage Wheel, then physically roll the wheel over the terminal during the 12-second probe.'
    }
    Wheel {
        if (-not $record.copy) { throw 'Complete Copy first.' }
        $probe = Join-Path $PSScriptRoot 'llm-e2e/suites/godot/windows/replays/conpty_probe.py'
        $trace = Join-Path $Evidence 'physical-wheel.json'
        Write-Host 'Roll the physical mouse wheel over this terminal now.'
        & python $probe $trace
        if ($LASTEXITCODE -ne 0) { throw 'Wheel/query probe failed; retain the trace and retry.' }
        $wheel = Get-Content -LiteralPath $trace -Raw | ConvertFrom-Json
        if (-not ($wheel.wheel -and $wheel.colors)) { throw 'Missing wheel or terminal-query replies.' }
        $record.wheel = $true
        Write-Host 'Wheel bytes received. Run -Stage Review after reviewing your recording.'
    }
    Review {
        if (-not ($record.interrupt -and $record.copy -and $record.wheel)) { throw 'Complete all three checks first.' }
        if ((Read-Host 'Were Ctrl+C interrupt, Ctrl+Shift+C copy and wheel actions physical, without event injection? Type YES') -cne 'YES') { throw 'Physical input remains unverified.' }
        if ((Read-Host 'Was Windows display scaling 150%, with readable text and no input/visual failures in the recording? Type YES') -cne 'YES') { throw '150% visual review remains unverified.' }
        $record.physical_input_attested = $true
        $record.scale_150_attested = $true
        $record.status = 'pass'
        Write-Host 'This shell passed the guided physical-input subset. Keep the recording beside the JSON receipts.'
    }
}
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath -Encoding UTF8
