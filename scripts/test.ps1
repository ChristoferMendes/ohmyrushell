#requires -Version 7.2
<#
.SYNOPSIS
Run formatting, linting, builds and all non-interactive tests, just like CI.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })

function Invoke-Checked {
    param([string] $Executable, [string[]] $Arguments)
    Write-Host "`n> $Executable $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Falhou (exit $LASTEXITCODE): $Executable $($Arguments -join ' ')" }
}

Push-Location $project
try {
    Invoke-Checked cargo @('fmt', '--all', '--check')
    Invoke-Checked cargo @('clippy', '--locked', '--all-targets', '--', '-D', 'warnings')
    Invoke-Checked cargo @('test', '--locked')
    Invoke-Checked cargo @('build', '--release', '--locked', '--target-dir', (Join-Path $project 'target'))
    # Native DLLs cannot be unloaded; isolate each module test in a fresh process.
    foreach ($test in @('installer-preflight', 'smoke', 'listing', 'highlighting', 'installer')) {
        Invoke-Checked $shell @('-NoLogo', '-NoProfile', '-File', (Join-Path $project "tests/$test.ps1"))
    }
    Write-Host "`nTodas as verificacoes passaram." -ForegroundColor Green
} finally {
    Pop-Location
}
