#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $ModulePath, [switch] $NoCompile, [switch] $WithoutReadLine)
$ErrorActionPreference = 'Stop'
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
if ($WithoutReadLine) {
    # Preserve the optional-PSReadLine path on minimal/headless installations.
    Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
    $env:PSModulePath = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    $original = ${function:prompt}
    Import-Module $ModulePath
    Assert (-not ('OhMyRushell.CommandHighlighting' -as [type])) 'Unexpected PSReadLine dependency.'
    Assert ((prompt).Contains([string][char]0x276f)) 'Native-only prompt failed.'
    Remove-Module ohmyrushell
    Assert (${function:prompt} -eq $original) 'Native-only prompt not restored.'
    Write-Output 'STARTUP_OK'
    return
}
Import-Module PSReadLine
if ($NoCompile) {
    # Fail if opening an installed module invokes the compiler, even with an
    # empty user cache. Permit only loading the shipped assembly.
    function global:Add-Type {
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $LiteralPath)
        Microsoft.PowerShell.Utility\Add-Type -LiteralPath $LiteralPath -ErrorAction Stop
    }
}
function global:ohmyrushell_startup_live { throw 'Do not execute while highlighting.' }
Set-Alias -Name g -Value git -Scope Global
Set-Alias -Name ls -Value Write-Output -Scope Global -Force
Set-Alias -Name ohmyrushell_startup_alias -Value ohmyrushell_startup_live -Scope Global
Set-PSReadLineKeyHandler -Chord Ctrl+d -BriefDescription StartupCustom -ScriptBlock { }
$paletteProperties = @('CommandColor', 'ParameterColor', 'StringColor', 'VariableColor', 'NumberColor',
    'OperatorColor', 'CommentColor', 'KeywordColor', 'ErrorColor', 'ContinuationPromptColor')
function Get-Palette {
    $options = Get-PSReadLineOption
    ($paletteProperties | ForEach-Object { [string]$options.$_ }) -join '|'
}
$palette = Get-Palette
$originalPrompt = ${function:prompt}
$beforeOptions = Get-PSReadLineOption
$prediction = [string]$beforeOptions.PredictionSource
$history = [string]$beforeOptions.HistorySaveStyle
Import-Module $ModulePath -ErrorAction Stop
Assert ([OhMyRushell.CommandHighlighting]::WaitForIndex(10000)) 'Discovery did not finish.'
Assert ((Get-Alias g).Definition -eq 'git') 'User Git alias changed.'
Assert ((Get-Alias ls).Definition -eq 'Get-OhMyRushellChildItem') 'ls feature not enabled.'
Assert ((Get-PSReadLineKeyHandler -Chord Ctrl+d).Function -eq 'StartupCustom') 'Custom Ctrl+D handler changed.'
Assert ((Get-PSReadLineOption).PredictionSource.ToString() -eq $prediction) 'Prediction setting changed.'
Assert ((Get-PSReadLineOption).HistorySaveStyle.ToString() -eq $history) 'History setting changed.'
foreach ($name in @('ohmyrushell_startup_live', 'ohmyrushell_startup_alias', 'g',
    'Invoke-StartupUnloaded', 'StartupMetadata\Invoke-StartupUnloaded')) {
    Assert ([OhMyRushell.CommandHighlighting]::Classify($name).ToString() -eq 'Valid') "Command lost: $name"
}
Assert ([OhMyRushell.CommandHighlighting]::Classify('Initialize-OhMyRushellHighlighting').ToString() -eq 'Invalid') 'Private module function exposed as a command.'
Assert (-not (Get-Module StartupMetadata)) 'Metadata discovery imported a user module.'
Assert (-not (Test-Path -LiteralPath $env:OHMYRUSHELL_STARTUP_SENTINEL)) 'Discovery executed user code.'
Assert ((prompt).Contains([string][char]0x276f)) 'Themed prompt missing.'
Assert ([OhMyRushell.Native].Assembly -eq [OhMyRushell.CommandHighlighting].Assembly) 'Expected a single combined bridge.'
if ($NoCompile) {
    Assert ([OhMyRushell.Native].Assembly.Location -match '[/\\]native[/\\]managed[/\\]') 'Packaged bridge not used.'
}
# Live names must be refreshed, not replaced by a stale cross-session cache.
Remove-Item Function:\ohmyrushell_startup_live
$null = prompt
Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_startup_live').ToString() -eq 'Invalid') 'Removed function stayed valid.'
# Explicit refresh must remain synchronous, including while startup discovery runs.
Update-OhMyRushellCommandCache
Assert ([OhMyRushell.CommandHighlighting]::WaitForIndex(10000)) 'Manual refresh failed.'
Disable-OhMyRushell
Assert ((Get-Palette) -eq $palette) 'Not all original colors restored.'
Assert (${function:prompt} -eq $originalPrompt) 'Original prompt not restored.'
Assert ((Get-Alias ls).Definition -eq 'Write-Output') 'Custom ls alias not restored.'
Assert ((Get-Alias g).Definition -eq 'git') 'Git alias lost on disable.'
Enable-OhMyRushell
Remove-Module ohmyrushell
Assert ((Get-Palette) -eq $palette) 'Remove-Module did not restore colors.'
Assert ((Get-Alias ls).Definition -eq 'Write-Output') 'Remove-Module did not restore ls.'
Assert ((Get-Alias g).Definition -eq 'git') 'Git alias lost on remove.'
Write-Output 'STARTUP_OK'
