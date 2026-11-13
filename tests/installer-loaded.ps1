#requires -Version 7.2
# Helper: use a separate process so the parent can clean up its mapped DLL later.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ModulePath,
    [Parameter(Mandatory)] [string] $InstallerPath
)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath
$null = prompt
$loadedLibrary = [OhMyRushell.Native]::LibraryPath
$oldRootModule = (Import-PowerShellDataFile -LiteralPath $ModulePath).RootModule
$source = Split-Path $InstallerPath -Parent
Add-Content -LiteralPath (Join-Path $source 'powershell/Listing.ps1') -Value "`n# Update while the previous release is loaded."
$messages = (& $InstallerPath -NoBuild -Destination (Split-Path $ModulePath -Parent) 6>&1 | Out-String)
if ($messages -notmatch 'A sessao atual continua') { throw 'Instalador sugeriu hot reload de uma biblioteca em uso.' }
if ((Import-PowerShellDataFile -LiteralPath $ModulePath).RootModule -eq $oldRootModule) { throw 'Atualizacao com modulo carregado nao foi publicada.' }
if ([OhMyRushell.Native]::LibraryPath -ne $loadedLibrary) { throw 'Instalacao trocou a biblioteca da sessao atual.' }
if (-not (prompt).Contains([string][char]0x276f)) { throw 'Instalar quebrou o prompt da sessao atual.' }
Remove-Module ohmyrushell
Write-Host 'Loaded-module update OK: nova release publicada; sessao anterior preservada.' -ForegroundColor Green
