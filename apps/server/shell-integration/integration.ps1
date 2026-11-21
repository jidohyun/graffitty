# Loaded after the user's normal PowerShell profile.
if ($env:GRAFFITTY_SHELL_SKIP_ALL -eq '1') { return }
if ($env:GRAFFITTY_BIN) {
    $env:PATH = (Split-Path -Parent $env:GRAFFITTY_BIN) + [IO.Path]::PathSeparator + $env:PATH
}
if (Test-Path Function:\global:__GraffittyOriginalPrompt) { return }
$function:global:__GraffittyOriginalPrompt = $function:prompt
# Emit the command-output boundary after the line editor has accepted its input,
# before PowerShell executes it. Prompt-only A/B/D markers cannot identify output.
if (-not (Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue
}
if (Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue) {
    $function:global:__GraffittyOriginalReadLine = $function:PSConsoleHostReadLine
    function global:PSConsoleHostReadLine {
        $line = & $function:__GraffittyOriginalReadLine
        if ($env:GRAFFITTY_SHELL_SKIP_SEMANTIC_ZONES -ne '1') {
            [Console]::Write("$([char]27)]133;C$([char]7)")
        }
        $line
    }
}
function global:prompt {
    $succeeded = $?
    $escape = [char]27
    if ($PWD.Provider.Name -eq 'FileSystem') {
        [Environment]::CurrentDirectory = $PWD.ProviderPath
    }
    if ($env:GRAFFITTY_SHELL_SKIP_CWD -ne '1' -and $PWD.Provider.Name -eq 'FileSystem') {
        $uri = [Uri]::new($PWD.ProviderPath + [IO.Path]::DirectorySeparatorChar)
        [Console]::Write("${escape}]7;$($uri.AbsoluteUri)$([char]7)")
    }
    if ($env:GRAFFITTY_SHELL_SKIP_SEMANTIC_ZONES -ne '1') {
        [Console]::Write("${escape}]133;D;$([int](-not $succeeded))$([char]7)${escape}]133;A$([char]7)")
    }
    $text = & $function:__GraffittyOriginalPrompt
    if ($env:GRAFFITTY_SHELL_SKIP_SEMANTIC_ZONES -ne '1') {
        $text += "${escape}]133;B$([char]7)"
    }
    $text
}
