#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $Path = $PWD.Path,
    [ValidateRange(1, 10000)] [int] $Iterations = 100,
    [string] $ModulePath = (Join-Path $PSScriptRoot '../powershell/ohmyrushell.psd1')
)
$ErrorActionPreference = 'Stop'
$directory = (Resolve-Path -LiteralPath $Path).ProviderPath
Import-Module $ModulePath
$timer = [Diagnostics.Stopwatch]::StartNew()
$first = [OhMyRushell.Native]::Render($directory, $true)
$timer.Stop()
$coldMs = $timer.Elapsed.TotalMilliseconds
$plain = [regex]::Replace($first, '\x1b\[[0-9;]*m', '')
if ($plain -match '(?m)  git:\([^\r\n]*\) !\r?$') { throw "Native Git query failed: $plain" }
for ($i = 0; $i -lt 10; $i++) { $null = [OhMyRushell.Native]::Render($directory, $true) }
$nativeTimes = [Collections.Generic.List[double]]::new()
for ($i = 0; $i -lt $Iterations; $i++) {
    $timer.Restart()
    $null = [OhMyRushell.Native]::Render($directory, $true)
    $timer.Stop()
    $nativeTimes.Add($timer.Elapsed.TotalMilliseconds)
}
$native = @($nativeTimes | Sort-Object)
Push-Location -LiteralPath $directory
try {
    for ($i = 0; $i -lt 5; $i++) { $null = prompt }
    $promptTimes = [Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $timer.Restart()
        $null = prompt
        $timer.Stop()
        $promptTimes.Add($timer.Elapsed.TotalMilliseconds)
    }
} finally { Pop-Location }
$full = @($promptTimes | Sort-Object)
$p50 = [int][Math]::Floor(($Iterations - 1) * 0.50)
$p95 = [int][Math]::Floor(($Iterations - 1) * 0.95)
Write-Host "Directory: $directory"
Write-Host ('First native call: {0:N3} ms (module import excluded)' -f $coldMs)
Write-Host ('Native Git + Rust render: p50={0:N3} ms p95={1:N3} ms' -f $native[$p50], $native[$p95])
Write-Host ('Full PowerShell prompt: p50={0:N3} ms p95={1:N3} ms ({2} calls)' -f $full[$p50], $full[$p95], $Iterations)
