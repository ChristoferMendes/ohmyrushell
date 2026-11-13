#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$project = Split-Path $PSScriptRoot -Parent
$shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ohmyrushell-startup-' + [Guid]::NewGuid())
$cache = Join-Path $temporary cache
$oldCache = $env:OHMYRUSHELL_CACHE_HOME
$oldModules = $env:PSModulePath
$oldSentinel = $env:OHMYRUSHELL_STARTUP_SENTINEL
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
$libraryName = if ($IsWindows) { 'ohmyrushell_core.dll' } elseif ($IsMacOS) { 'libohmyrushell_core.dylib' } else { 'libohmyrushell_core.so' }
function Start-Child([string] $Manifest, [switch] $NoCompile, [switch] $WithoutReadLine) {
    $info = [Diagnostics.ProcessStartInfo]::new($shell)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'startup-child.ps1'), '-ModulePath', $Manifest)) {
        $info.ArgumentList.Add($argument)
    }
    if ($NoCompile) { $info.ArgumentList.Add('-NoCompile') }
    if ($WithoutReadLine) { $info.ArgumentList.Add('-WithoutReadLine') }
    $process = [Diagnostics.Process]::Start($info)
    $processes.Add($process)
    return $process
}
function Complete-Child([Diagnostics.Process] $Process) {
    $stdout = $Process.StandardOutput.ReadToEndAsync()
    $stderr = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit(30000)) { throw 'Startup child timed out.' }
    $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Assert ($Process.ExitCode -eq 0 -and $text.Contains('STARTUP_OK')) "Startup child failed: $text"
}
try {
    $env:OHMYRUSHELL_CACHE_HOME = $cache
    $env:OHMYRUSHELL_STARTUP_SENTINEL = Join-Path $temporary must-not-exist
    $metadata = Join-Path $temporary 'modules/StartupMetadata'
    $null = [IO.Directory]::CreateDirectory($metadata)
    [IO.File]::WriteAllText((Join-Path $metadata 'StartupMetadata.psm1'), @'
[IO.File]::WriteAllText($env:OHMYRUSHELL_STARTUP_SENTINEL, 'module imported')
function Invoke-StartupUnloaded { throw 'Never execute this function.' }
Export-ModuleMember -Function Invoke-StartupUnloaded
'@)
    [IO.File]::WriteAllText((Join-Path $metadata 'StartupMetadata.psd1'), "@{ RootModule = 'StartupMetadata.psm1'; ModuleVersion = '1.0.0'; FunctionsToExport = @('Invoke-StartupUnloaded') }")
    $env:PSModulePath = (Split-Path $metadata -Parent) + [IO.Path]::PathSeparator + $oldModules
    $manifests = foreach ($name in @('release-one', 'release-two')) {
        $fixture = Join-Path $temporary $name
        $null = [IO.Directory]::CreateDirectory((Join-Path $fixture native))
        Copy-Item -Path (Join-Path $project 'powershell/*.*') -Destination $fixture
        Copy-Item -LiteralPath (Join-Path $project "target/release/$libraryName") -Destination (Join-Path $fixture native)
        Join-Path $fixture ohmyrushell.psd1
    }
    # Concurrent cold imports must publish complete assemblies atomically.
    $children = @(Start-Child $manifests[0]; Start-Child $manifests[0]; Start-Child $manifests[1])
    foreach ($child in $children) { Complete-Child $child }
    $assemblies = @(Get-ChildItem -LiteralPath $cache -Filter '*.dll' -Recurse)
    Assert ($assemblies.Count -eq 1) 'Bridges were not shared across releases, or temporary DLLs leaked.'
    $before = (Get-FileHash -LiteralPath $assemblies[0].FullName).Hash
    $writeTime = $assemblies[0].LastWriteTimeUtc
    Complete-Child (Start-Child $manifests[1])
    Assert ((Get-FileHash -LiteralPath $assemblies[0].FullName).Hash -eq $before) 'Warm import modified cached assembly.'
    Assert ((Get-Item -LiteralPath $assemblies[0].FullName).LastWriteTimeUtc -eq $writeTime) 'Warm import recompiled bridge.'

    Complete-Child (Start-Child $manifests[0] -WithoutReadLine)

    # The installer ships the assembly; no cache/compilation is needed to open it.
    $destination = Join-Path $temporary installed
    & (Join-Path $project install.ps1) -NoBuild -Destination $destination
    $manifest = Join-Path $destination ohmyrushell.psd1
    $release = Split-Path (Join-Path $destination (Import-PowerShellDataFile $manifest).RootModule) -Parent
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $release 'native/managed') -Filter '*.dll').Count -eq 1) 'Installer did not ship bridge.'
    Remove-Item -LiteralPath $cache -Recurse -Force
    Complete-Child (Start-Child $manifest -NoCompile)
    Assert (-not (Test-Path -LiteralPath $cache)) 'Installed startup recreated the compiler cache.'
    Assert (-not (Test-Path -LiteralPath $env:OHMYRUSHELL_STARTUP_SENTINEL)) 'Startup executed user module code.'
    Write-Host 'Startup OK: cold/concurrent/warm imports, shared bridge, no compiler after install, features/aliases/settings preserved.' -ForegroundColor Green
} finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $env:OHMYRUSHELL_CACHE_HOME = $oldCache
    $env:PSModulePath = $oldModules
    $env:OHMYRUSHELL_STARTUP_SENTINEL = $oldSentinel
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
