#requires -Version 7.2
# Installer worker: compile without loading types into the caller's session.
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $OutputPath)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/AssemblyCache.ps1"
$readLine = Get-Module PSReadLine
if (-not $readLine -and (Get-Module -ListAvailable PSReadLine)) {
    $readLine = Import-Module PSReadLine -PassThru -ErrorAction Stop
}
$kind = if ($readLine) { 'integration' } else { 'bridge' }
$sources = @("$PSScriptRoot/Native.cs")
if ($readLine) { $sources += "$PSScriptRoot/CommandHighlighting.cs" }
$assembly = Get-OhMyRushellAssembly -Source $sources -Kind $kind -ReadLine:([bool]$readLine)
$identity = Get-OhMyRushellAssemblyIdentity -ReadLine:([bool]$readLine)
$metadata = [pscustomobject]@{
    Source = [IO.Path]::GetFullPath($assembly)
    Relative = "native/managed/$kind-$identity.dll"
}
[IO.File]::WriteAllText($OutputPath, ($metadata | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
